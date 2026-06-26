import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

/// Captura facial nativa para Android usando câmera frontal + ML Kit FaceMesh.
///
/// Mantém a mesma API do capturador web para o jogo conseguir consumir ambos
/// como uma textura `ui.Image`.
class WebFaceCapture {
  static const _faceTextureSize = 256;
  static const _faceFill = 1.45;
  static const _minProcessGap = Duration(milliseconds: 120);
  static const _lostFaceGrace = Duration(milliseconds: 850);
  static const _orientations = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };
  static const _faceOvalIndexes = <int>[
    10,
    338,
    297,
    332,
    284,
    251,
    389,
    356,
    454,
    323,
    361,
    288,
    397,
    365,
    379,
    378,
    400,
    377,
    152,
    148,
    176,
    149,
    150,
    136,
    172,
    58,
    132,
    93,
    234,
    127,
    162,
    21,
    54,
    103,
    67,
    109,
  ];

  final FaceMeshDetector _detector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh,
  );

  CameraDescription? _camera;
  CameraController? _controller;
  Rect? _smoothedFaceCrop;
  DateTime? _lastFaceSeen;
  ui.Image? _pendingImage;
  int _pendingFrameId = 0;
  int _lastDeliveredFrameId = 0;
  bool _detecting = false;
  bool _starting = false;
  DateTime? _lastProcessAt;
  String _status = 'idle';
  String? _errorMessage;

  bool get isSupported => Platform.isAndroid;

  String get status => _status;

  String? get errorMessage => _errorMessage;

  bool get hasFace {
    final last = _lastFaceSeen;
    return last != null && DateTime.now().difference(last) < _lostFaceGrace;
  }

  Future<void> start() async {
    if (!isSupported || _status == 'live' || _starting) return;
    _starting = true;
    _status = 'starting';
    _errorMessage = null;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('cameraNotFound', 'Nenhuma câmera encontrada.');
      }

      _camera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        _camera!,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      _controller = controller;
      await controller.initialize();
      await controller.startImageStream(_processCameraImage);
      _status = 'live';
    } on CameraException catch (error) {
      _status = 'error';
      _errorMessage = _friendlyCameraError(error);
      await _disposeCamera();
    } catch (error) {
      _status = 'error';
      _errorMessage = error.toString();
      await _disposeCamera();
    } finally {
      _starting = false;
    }
  }

  void stop() {
    _status = 'idle';
    unawaited(_disposeCamera());
  }

  Future<ui.Image?> takeFrameIfNew() async {
    if (_pendingImage == null || _pendingFrameId == _lastDeliveredFrameId) {
      return null;
    }
    final image = _pendingImage;
    _pendingImage = null;
    _lastDeliveredFrameId = _pendingFrameId;
    return image;
  }

  Future<void> _disposeCamera() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
    }
    _clearPendingImage();
    _smoothedFaceCrop = null;
  }

  void _clearPendingImage() {
    _pendingImage?.dispose();
    _pendingImage = null;
  }

  String _friendlyCameraError(CameraException error) {
    if (error.code == 'CameraAccessDenied' ||
        error.code == 'cameraPermission') {
      return 'Permissão de câmera negada no Android.';
    }
    return '${error.code}: ${error.description ?? error.code}';
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_detecting) return;
    final now = DateTime.now();
    final lastProcessAt = _lastProcessAt;
    if (lastProcessAt != null &&
        now.difference(lastProcessAt) < _minProcessGap) {
      return;
    }
    _lastProcessAt = now;
    _detecting = true;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final meshes = await _detector.processImage(inputImage);
      final usableMeshes = meshes.where(_isCredibleFaceMesh).toList()
        ..sort((a, b) {
          final aa = a.boundingBox.width * a.boundingBox.height;
          final bb = b.boundingBox.width * b.boundingBox.height;
          return bb.compareTo(aa);
        });

      if (usableMeshes.isEmpty) {
        if (!hasFace) {
          _smoothedFaceCrop = null;
          _clearPendingImage();
        }
        return;
      }

      final texture = await _buildFaceTexture(image, usableMeshes.first);
      if (texture == null) return;
      _lastFaceSeen = DateTime.now();
      _clearPendingImage();
      _pendingImage = texture;
      _pendingFrameId++;
    } catch (_) {
      // Frames isolados podem falhar durante rotação/luz baixa. Ignoramos para
      // manter o loop do jogo fluido.
    } finally {
      _detecting = false;
    }
  }

  Future<ui.Image?> _buildFaceTexture(CameraImage image, FaceMesh mesh) async {
    if (image.format.group != ImageFormatGroup.nv21) return null;
    final rotationDegrees = _cameraInputRotationDegrees();
    if (rotationDegrees == null) return null;

    final orientedFrame = _rotateRgbaFrame(
      _nv21ToRgbaFrame(image),
      rotationDegrees,
    );
    final orientedSize = Size(
      orientedFrame.width.toDouble(),
      orientedFrame.height.toDouble(),
    );

    final rawContour = _faceOvalPoints(mesh);
    if (rawContour == null || rawContour.length < 8) return null;

    final crop = _pickFaceCrop(rawContour, orientedSize);
    if (crop == null) return null;

    final sourceRect = _faceMirrorSourceRect(crop.bounds, orientedSize);
    final rawImage = await _decodeRgba(
      orientedFrame.pixels,
      orientedFrame.width,
      orientedFrame.height,
    );
    final texture = await _renderFaceMirrorTexture(
      rawImage: rawImage,
      sourceRect: sourceRect,
      contourPoints: crop.contourPoints,
    );
    rawImage.dispose();
    return texture;
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final rotationDegrees = _cameraInputRotationDegrees();
    if (rotationDegrees == null) return null;
    final rotation = InputImageRotationValue.fromRawValue(rotationDegrees);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null || format != InputImageFormat.nv21) return null;
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  int? _cameraInputRotationDegrees() {
    final camera = _camera;
    final controller = _controller;
    if (camera == null || controller == null) return null;

    final deviceOrientation = controller.value.deviceOrientation;
    final rotation = _orientations[deviceOrientation];
    if (rotation == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    if (camera.lensDirection == CameraLensDirection.front) {
      return (sensorOrientation + rotation) % 360;
    }
    return (sensorOrientation - rotation + 360) % 360;
  }

  bool _isCredibleFaceMesh(FaceMesh mesh) {
    final box = mesh.boundingBox;
    if (box.width <= 0 || box.height <= 0) return false;
    final ratio = box.width / box.height;
    if (ratio < 0.25 || ratio > 1.85) return false;
    final contourPoints = _faceOvalPoints(mesh)?.length ?? 0;
    return contourPoints >= 8 &&
        mesh.points.length >= 120 &&
        box.width * box.height > 900;
  }

  List<Offset>? _faceOvalPoints(FaceMesh mesh) {
    final contour = mesh.contours[FaceMeshContourType.faceOval];
    final contourPoints = contour
        ?.map((point) => Offset(point.x, point.y))
        .toList(growable: false);
    if (contourPoints != null && contourPoints.length >= 8) {
      return contourPoints;
    }

    final byIndex = <int, FaceMeshPoint>{
      for (final point in mesh.points) point.index: point,
    };
    final points = <Offset>[];
    for (final index in _faceOvalIndexes) {
      final point = byIndex[index];
      if (point != null) points.add(Offset(point.x, point.y));
    }
    return points.length >= 8 ? points : null;
  }

  _FaceCrop? _pickFaceCrop(List<Offset> contour, Size imageSize) {
    final transforms = <List<Offset> Function(List<Offset>)>[
      (points) => points,
      (points) => points
          .map((point) => Offset(imageSize.width - point.dx, point.dy))
          .toList(growable: false),
      (points) => points
          .map((point) => Offset(point.dy, imageSize.height - point.dx))
          .toList(growable: false),
      (points) => points
          .map((point) => Offset(imageSize.width - point.dy, point.dx))
          .toList(growable: false),
      (points) => points
          .map(
            (point) => Offset(
              imageSize.width - point.dx,
              imageSize.height - point.dy,
            ),
          )
          .toList(growable: false),
    ];

    _FaceCrop? best;
    var bestScore = double.infinity;
    for (final transform in transforms) {
      final transformedContour = transform(contour);
      final candidate = _boundsForPoints(transformedContour);
      final clipped = candidate.intersect(
        Rect.fromLTWH(0, 0, imageSize.width, imageSize.height),
      );
      if (clipped.width < imageSize.width * 0.04 ||
          clipped.height < imageSize.height * 0.04) {
        continue;
      }
      final aspect = clipped.width / clipped.height;
      if (aspect < 0.28 || aspect > 1.75) continue;
      final center = clipped.center;
      final centerScore = (center.dx / imageSize.width - 0.5).abs() * 0.35 +
          (center.dy / imageSize.height - 0.5).abs() * 0.35;
      final sizeScore = ((clipped.width * clipped.height) /
                  (imageSize.width * imageSize.height) -
              0.18)
          .abs();
      final outsidePenalty =
          (candidate.width * candidate.height - clipped.width * clipped.height)
                  .abs() /
              max(1, candidate.width * candidate.height);
      final score = centerScore + sizeScore + outsidePenalty * 2;
      if (score < bestScore) {
        bestScore = score;
        best = _FaceCrop(bounds: clipped, contourPoints: transformedContour);
      }
    }
    return best;
  }

  Rect _boundsForPoints(List<Offset> points) {
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final point in points) {
      left = min(left, point.dx);
      top = min(top, point.dy);
      right = max(right, point.dx);
      bottom = max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Rect _faceMirrorSourceRect(Rect face, Size imageSize) {
    // Mantém o recorte bem justo como no pipeline web. O zoom posterior
    // (_faceFill) faz a face preencher o oval e evita mostrar cenário/camisa.
    final padX = face.width * 0.0;
    final padY = face.height * 0.0;
    var expanded = Rect.fromLTRB(
      face.left - padX,
      face.top - padY,
      face.right + padX,
      face.bottom + padY,
    );

    final previous = _smoothedFaceCrop;
    if (previous != null) {
      expanded = Rect.lerp(expanded, previous, 0.40)!;
    }

    final left = expanded.left
        .clamp(
          0.0,
          max(0.0, imageSize.width - expanded.width),
        )
        .toDouble();
    final top = expanded.top
        .clamp(
          0.0,
          max(0.0, imageSize.height - expanded.height),
        )
        .toDouble();
    final rect = Rect.fromLTWH(left, top, expanded.width, expanded.height);
    _smoothedFaceCrop = rect;
    return rect;
  }

  Future<ui.Image> _renderFaceMirrorTexture({
    required ui.Image rawImage,
    required Rect sourceRect,
    required List<Offset> contourPoints,
  }) async {
    final recorder = ui.PictureRecorder();
    final textureRect = Rect.fromLTWH(
      0,
      0,
      _faceTextureSize.toDouble(),
      _faceTextureSize.toDouble(),
    );
    final canvas = Canvas(recorder, textureRect);
    final maskPath = _faceTexturePath(
      contourPoints,
      sourceRect,
      scale: _faceFill,
    );

    canvas.save();
    canvas.clipPath(maskPath);
    canvas.translate(_faceTextureSize / 2, _faceTextureSize / 2);
    canvas.scale(_faceFill, _faceFill);
    canvas.translate(-_faceTextureSize / 2, -_faceTextureSize / 2);
    canvas.translate(_faceTextureSize.toDouble(), 0);
    canvas.scale(-1, 1);
    canvas.drawImageRect(
      rawImage,
      sourceRect,
      textureRect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
    canvas.restore();

    final picture = recorder.endRecording();
    final texture = await picture.toImage(_faceTextureSize, _faceTextureSize);
    picture.dispose();
    return texture;
  }

  Path _faceTexturePath(
    List<Offset> points,
    Rect sourceRect, {
    required double scale,
  }) {
    final path = Path();
    final center = Offset(_faceTextureSize / 2, _faceTextureSize / 2);

    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final u =
          ((point.dx - sourceRect.left) / sourceRect.width).clamp(0.0, 1.0);
      final v =
          ((point.dy - sourceRect.top) / sourceRect.height).clamp(0.0, 1.0);
      final mapped = Offset(
        (1 - u) * _faceTextureSize,
        v * _faceTextureSize,
      );
      final scaled = center + (mapped - center) * scale;
      if (i == 0) {
        path.moveTo(scaled.dx, scaled.dy);
      } else {
        path.lineTo(scaled.dx, scaled.dy);
      }
    }
    path.close();
    return path;
  }

  _RgbaFrame _nv21ToRgbaFrame(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final nv21 = image.planes.first.bytes;
    final rgba = Uint8List(width * height * 4);
    var out = 0;
    final frameSize = width * height;

    for (var y = 0; y < height; y++) {
      final uvRow = frameSize + (y >> 1) * width;
      for (var x = 0; x < width; x++) {
        final yp = y * width + x;
        final uvp = uvRow + (x & ~1);
        final yValue = nv21[yp] & 0xFF;
        final v = (uvp < nv21.length ? nv21[uvp] : 128) - 128;
        final u = (uvp + 1 < nv21.length ? nv21[uvp + 1] : 128) - 128;

        final yf = yValue.toDouble();
        final r = (yf + 1.402 * v).round().clamp(0, 255);
        final g = (yf - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
        final b = (yf + 1.772 * u).round().clamp(0, 255);

        rgba[out++] = r;
        rgba[out++] = g;
        rgba[out++] = b;
        rgba[out++] = 255;
      }
    }
    return _RgbaFrame(pixels: rgba, width: width, height: height);
  }

  _RgbaFrame _rotateRgbaFrame(_RgbaFrame frame, int degrees) {
    final normalizedDegrees = ((degrees % 360) + 360) % 360;
    if (normalizedDegrees == 0) return frame;

    final width = frame.width;
    final height = frame.height;
    final rotatedWidth = normalizedDegrees == 180 ? width : height;
    final rotatedHeight = normalizedDegrees == 180 ? height : width;
    final rotated = Uint8List(rotatedWidth * rotatedHeight * 4);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        late final int dx;
        late final int dy;
        switch (normalizedDegrees) {
          case 90:
            dx = height - y - 1;
            dy = x;
          case 180:
            dx = width - x - 1;
            dy = height - y - 1;
          case 270:
            dx = y;
            dy = width - x - 1;
          default:
            dx = x;
            dy = y;
        }

        final src = (y * width + x) * 4;
        final dst = (dy * rotatedWidth + dx) * 4;
        rotated[dst] = frame.pixels[src];
        rotated[dst + 1] = frame.pixels[src + 1];
        rotated[dst + 2] = frame.pixels[src + 2];
        rotated[dst + 3] = frame.pixels[src + 3];
      }
    }

    return _RgbaFrame(
      pixels: rotated,
      width: rotatedWidth,
      height: rotatedHeight,
    );
  }

  Future<ui.Image> _decodeRgba(Uint8List pixels, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

class _FaceCrop {
  const _FaceCrop({
    required this.bounds,
    required this.contourPoints,
  });

  final Rect bounds;
  final List<Offset> contourPoints;
}

class _RgbaFrame {
  const _RgbaFrame({
    required this.pixels,
    required this.width,
    required this.height,
  });

  final Uint8List pixels;
  final int width;
  final int height;
}
