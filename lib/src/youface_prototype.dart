import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

import 'face_capture.dart';
import 'web_camera_probe.dart';

class YouFacePrototypeScreen extends StatefulWidget {
  const YouFacePrototypeScreen({super.key});

  @override
  State<YouFacePrototypeScreen> createState() => _YouFacePrototypeScreenState();
}

class _YouFacePrototypeScreenState extends State<YouFacePrototypeScreen>
    with SingleTickerProviderStateMixin {
  static const _orientations = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  late final AnimationController _clock;
  static const _faceTextureSize = 512;
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

  late final FaceMeshDetector _faceMeshDetector;

  CameraController? _cameraController;
  CameraDescription? _camera;
  bool _detecting = false;
  bool _cameraReady = false;
  String? _cameraError;
  DateTime? _lastFaceSeen;
  FaceTextureFrame? _faceFrame;
  Rect? _smoothedFaceCrop;
  int _faceCount = 0;

  // Captura facial no web (MediaPipe via ponte JS).
  WebFaceCapture? _webCapture;
  Timer? _webPollTimer;

  bool get _hasFreshFace {
    final last = _lastFaceSeen;
    if (last == null) return false;
    return DateTime.now().difference(last) < const Duration(milliseconds: 850);
  }

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    )..repeat();
    _faceMeshDetector = FaceMeshDetector(
      option: FaceMeshDetectorOptions.faceMesh,
    );
    unawaited(_initCamera());
  }

  Future<void> _initCamera() async {
    CameraException? lastCameraError;
    Object? lastUnexpectedError;
    try {
      if (kIsWeb) {
        await _initWebFaceCapture();
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraError = 'Nenhuma câmera encontrada.');
        return;
      }

      final orderedCameras = [
        ...cameras.where(
          (camera) => camera.lensDirection == CameraLensDirection.front,
        ),
        ...cameras.where(
          (camera) => camera.lensDirection != CameraLensDirection.front,
        ),
      ];
      final presets = kIsWeb
          ? const [ResolutionPreset.low, ResolutionPreset.medium]
          : const [
              ResolutionPreset.medium,
              ResolutionPreset.low,
              ResolutionPreset.high,
            ];

      for (final camera in orderedCameras) {
        for (final preset in presets) {
          CameraController? controller;
          try {
            controller = CameraController(
              camera,
              preset,
              enableAudio: false,
              imageFormatGroup: _cameraImageFormatGroup,
            );
            await controller.initialize();
            if (!mounted) {
              unawaited(controller.dispose());
              return;
            }

            _camera = camera;
            _cameraController = controller;
            setState(() {
              _cameraReady = true;
              _cameraError = null;
            });

            if (_supportsNativeFaceMesh) {
              await controller.startImageStream(_processCameraImage);
            }
            return;
          } on CameraException catch (e) {
            lastCameraError = e;
            unawaited(controller?.dispose());
          } catch (e) {
            lastUnexpectedError = e;
            unawaited(controller?.dispose());
          }
        }
      }

      if (!mounted) return;
      if (kIsWeb && await _recoverWithRawWebCameraProbe(lastCameraError)) {
        return;
      }
      final error = lastCameraError;
      setState(() {
        _cameraError = error == null
            ? (lastUnexpectedError?.toString() ??
                'Não consegui abrir a câmera.')
            : _friendlyCameraError(error);
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      if (kIsWeb && await _recoverWithRawWebCameraProbe(e)) {
        return;
      }
      setState(() => _cameraError = _friendlyCameraError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = e.toString());
    }
  }

  Future<void> _initWebFaceCapture() async {
    final capture = WebFaceCapture();
    if (!capture.isSupported) {
      // A ponte JS não carregou (CDN bloqueado?). Cai no teste simples só para
      // diferenciar "sem câmera" de "sem detector".
      await _initRawWebCameraProbe();
      return;
    }
    _webCapture = capture;
    await capture.start();
    if (!mounted) return;

    _webPollTimer = Timer.periodic(
      const Duration(milliseconds: 66),
      (_) => _pollWebFace(),
    );

    setState(() {
      _cameraReady = capture.status == 'live';
      _cameraError = capture.status == 'error' ? capture.errorMessage : null;
    });
  }

  Future<void> _pollWebFace() async {
    final capture = _webCapture;
    if (capture == null) return;

    final status = capture.status;
    final error = capture.errorMessage;
    final hasFace = capture.hasFace;

    ui.Image? next;
    try {
      next = await capture.takeFrameIfNew();
    } catch (_) {
      next = null;
    }
    if (!mounted) {
      next?.dispose();
      return;
    }

    setState(() {
      _cameraReady = status == 'live';
      _cameraError = status == 'error' ? error : null;
      if (hasFace) {
        _lastFaceSeen = DateTime.now();
        _faceCount = 1;
        if (next != null) {
          final old = _faceFrame;
          _faceFrame = FaceTextureFrame(image: next);
          old?.dispose();
        }
      } else {
        next?.dispose();
        _faceCount = 0;
        if (!_hasFreshFace) {
          final old = _faceFrame;
          _faceFrame = null;
          old?.dispose();
        }
      }
    });
  }

  Future<void> _initRawWebCameraProbe() async {
    final directError = await probeRawWebCameraAccess();
    if (!mounted) return;

    setState(() {
      _cameraReady = directError == null;
      _cameraError = directError == null
          ? null
          : 'Teste direto do navegador falhou: $directError';
    });
  }

  Future<bool> _recoverWithRawWebCameraProbe(CameraException? error) async {
    final directError = await probeRawWebCameraAccess();
    if (!mounted) return true;

    if (directError == null) {
      setState(() {
        _cameraReady = true;
        _cameraError = null;
      });
      return true;
    }

    setState(() {
      _cameraReady = false;
      _cameraError =
          '${error == null ? 'cameraNotReadable' : _friendlyCameraError(error)}\n'
          'Teste direto do navegador também falhou: $directError';
    });
    return true;
  }

  ImageFormatGroup? get _cameraImageFormatGroup {
    if (_isAndroid) return ImageFormatGroup.nv21;
    if (_isIOS) return ImageFormatGroup.bgra8888;
    return null;
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get _supportsNativeFaceMesh => _isAndroid || _isIOS;

  bool get _faceMeshAvailable =>
      _supportsNativeFaceMesh || (_webCapture?.isSupported ?? false);

  String _friendlyCameraError(CameraException error) {
    if (error.code == 'cameraNotReadable') {
      return 'cameraNotReadable: a câmera está ocupada ou bloqueada. Feche Teams/Zoom/Camera do Windows/outras abas e recarregue.';
    }
    if (error.code == 'CameraAccessDenied' ||
        error.code == 'cameraPermission') {
      return '${error.code}: permissão de câmera negada no navegador/sistema.';
    }
    return '${error.code}: ${error.description ?? error.code}';
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_detecting) return;
    _detecting = true;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final meshes = await _faceMeshDetector.processImage(inputImage);
      if (!mounted) return;

      final usableMeshes = meshes.where(_isCredibleFaceMesh).toList();
      usableMeshes.sort((a, b) {
        final aa = a.boundingBox.width * a.boundingBox.height;
        final bb = b.boundingBox.width * b.boundingBox.height;
        return bb.compareTo(aa);
      });

      final nextFrame = usableMeshes.isNotEmpty
          ? await _buildFaceTextureFrame(image, usableMeshes.first)
          : null;
      if (!mounted) {
        nextFrame?.dispose();
        return;
      }

      setState(() {
        _faceCount = usableMeshes.length;
        if (usableMeshes.isNotEmpty) {
          _lastFaceSeen = DateTime.now();
          if (nextFrame != null) {
            final oldFrame = _faceFrame;
            _faceFrame = nextFrame;
            oldFrame?.dispose();
          }
        } else {
          nextFrame?.dispose();
          if (!_hasFreshFace) {
            _smoothedFaceCrop = null;
            final oldFrame = _faceFrame;
            _faceFrame = null;
            oldFrame?.dispose();
          }
        }
      });
    } catch (_) {
      // Detector falhou em um frame isolado. Ignoramos para manter o preview
      // fluido; se vários frames falharem, o timer naturalmente mostra o
      // "sem sinal".
    } finally {
      _detecting = false;
    }
  }

  Future<FaceTextureFrame?> _buildFaceTextureFrame(
    CameraImage image,
    FaceMesh mesh,
  ) async {
    if (!_isAndroid || image.format.group != ImageFormatGroup.nv21) {
      return null;
    }
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
    if (rawContour == null || rawContour.length < 8) {
      return null;
    }
    final crop = _pickFaceCrop(rawContour, orientedSize);
    if (crop == null) return null;

    final sourceRect = _faceMirrorSourceRect(crop.bounds, orientedSize);
    final contour = crop.contourPoints;

    final rawImage = await _decodeRgba(
      orientedFrame.pixels,
      orientedFrame.width,
      orientedFrame.height,
    );
    final texture = await _renderFaceMirrorTexture(
      rawImage: rawImage,
      sourceRect: sourceRect,
      contourPoints: contour,
    );
    rawImage.dispose();

    return FaceTextureFrame(
      image: texture,
    );
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

  Rect _faceMirrorSourceRect(Rect face, Size imageSize) {
    final padX = face.width * 0.06;
    final padY = face.height * 0.08;
    var expanded = Rect.fromLTRB(
      face.left - padX,
      face.top - padY,
      face.right + padX,
      face.bottom + padY,
    );

    final center = expanded.center;
    final side = max(expanded.width, expanded.height).clamp(
      min(imageSize.width, imageSize.height) * 0.12,
      min(imageSize.width, imageSize.height) * 0.88,
    );
    expanded = Rect.fromCenter(center: center, width: side, height: side);

    final previous = _smoothedFaceCrop;
    if (previous != null) {
      expanded = Rect.lerp(expanded, previous, 0.40)!;
    }

    var left = expanded.left;
    var top = expanded.top;
    left = left.clamp(0.0, max(0.0, imageSize.width - expanded.width));
    top = top.clamp(0.0, max(0.0, imageSize.height - expanded.height));
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
    final maskPath = _faceTexturePath(contourPoints, sourceRect, scale: 1.02);

    canvas.drawRect(
      textureRect,
      Paint()..color = const Color(0xFFC48768),
    );

    canvas.save();
    canvas.clipPath(maskPath);
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

    canvas.drawPath(
      _faceTexturePath(contourPoints, sourceRect, scale: 1.01),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = const Color(0x30000000)
        ..isAntiAlias = true,
    );

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
    final center = Offset(
      _faceTextureSize / 2,
      _faceTextureSize / 2,
    );

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

  int? _cameraInputRotationDegrees() {
    final camera = _camera;
    final controller = _cameraController;
    if (camera == null || controller == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    if (_isIOS) return sensorOrientation;
    if (!_isAndroid) return 0;

    var rotationCompensation =
        _orientations[controller.value.deviceOrientation];
    if (rotationCompensation == null) return null;
    if (camera.lensDirection == CameraLensDirection.front) {
      rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
    } else {
      rotationCompensation =
          (sensorOrientation - rotationCompensation + 360) % 360;
    }
    return rotationCompensation;
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final rotationDegrees = _cameraInputRotationDegrees();
    if (rotationDegrees == null) return null;
    final rotation = InputImageRotationValue.fromRawValue(rotationDegrees);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (_isAndroid && format != InputImageFormat.nv21) ||
        (_isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }

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

  @override
  void dispose() {
    _webPollTimer?.cancel();
    _webCapture?.stop();
    final controller = _cameraController;
    if (controller != null && controller.value.isStreamingImages) {
      unawaited(controller.stopImageStream());
    }
    unawaited(controller?.dispose());
    unawaited(_faceMeshDetector.close());
    _faceFrame?.dispose();
    _clock.dispose();
    super.dispose();
  }

  /// Toque na tela: no web, um gesto do usuário é a forma mais confiável de
  /// (re)abrir a câmera — então usamos o toque para tentar reativar quando ela
  /// não está ao vivo (ex.: estava ocupada por outro app e foi liberada).
  void _onScreenTap() {
    if (!kIsWeb) return;
    final capture = _webCapture;
    if (capture != null && capture.status != 'live') {
      unawaited(capture.start());
    }
  }

  String get _hintText {
    if (kIsWeb && _webCapture != null && _webCapture!.status != 'live') {
      return 'TOQUE NA TELA PARA ATIVAR A CÂMERA';
    }
    return 'SAIA DA CÂMERA PARA VER O CHUVISCO';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF6FC4FF),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onScreenTap,
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _clock,
            builder: (context, _) {
              final jump = sin(_clock.value * pi);
              return Stack(
                children: [
                  const Positioned.fill(child: _NeutralBackdrop()),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 58),
                    child: Transform.translate(
                      offset: Offset(0, -58 * jump),
                      child: YouFaceMascot(
                        ready: _cameraReady,
                        hasFace: _hasFreshFace,
                        faceFrame: _faceFrame,
                        error: _cameraError,
                        tick: _clock.value,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  top: 12,
                  child: _StatusPanel(
                    cameraReady: _cameraReady,
                    hasFace: _hasFreshFace,
                    faceCount: _faceCount,
                    faceMeshAvailable: _faceMeshAvailable,
                    error: _cameraError,
                  ),
                ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 12,
                    child: Text(
                      _hintText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.62),
                        fontSize: 10,
                        fontFamily: 'PressStart2P',
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.cameraReady,
    required this.hasFace,
    required this.faceCount,
    required this.faceMeshAvailable,
    this.error,
  });

  final bool cameraReady;
  final bool hasFace;
  final int faceCount;
  final bool faceMeshAvailable;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = error != null
        ? 'CÂMERA: ERRO'
        : !cameraReady
            ? 'CÂMERA: INICIANDO'
            : !faceMeshAvailable
                ? 'WEB: CÂMERA OK • FACE MESH NO ANDROID'
                : hasFace
                    ? 'ROSTO OK • $faceCount'
                    : 'SEM ROSTO • TV SEM SINAL';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xCC101018),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'YOUFACE CAMERA TEST',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFFFE45C),
              fontSize: 13,
              fontFamily: 'PressStart2P',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: hasFace ? const Color(0xFF73FF57) : Colors.white,
              fontSize: 10,
              fontFamily: 'PressStart2P',
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFF8A80),
                fontSize: 9,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _YouFaceSpriteFrame {
  const _YouFaceSpriteFrame({
    required this.source,
    required this.screen,
  });

  final Rect source;
  final Rect screen;
}

class YouFaceMascot extends StatefulWidget {
  const YouFaceMascot({
    required this.ready,
    required this.hasFace,
    required this.tick,
    this.faceFrame,
    this.error,
    super.key,
  });

  final bool ready;
  final bool hasFace;
  final FaceTextureFrame? faceFrame;
  final String? error;
  final double tick;

  @override
  State<YouFaceMascot> createState() => _YouFaceMascotState();
}

class _YouFaceMascotState extends State<YouFaceMascot> {
  late final Future<ui.Image> _spriteSheet = _loadSpriteSheet();

  Future<ui.Image> _loadSpriteSheet() async {
    final data =
        await rootBundle.load('assets/youface/youface-sprites-concept.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return image;

    final pixels = Uint8List.fromList(byteData.buffer.asUint8List());
    for (var i = 0; i < pixels.length; i += 4) {
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      final isMagentaKey = r > 220 && g < 80 && b > 180;
      if (isMagentaKey) {
        pixels[i + 3] = 0;
      }
    }

    final keyed = await _decodeImageFromPixels(
      pixels,
      image.width,
      image.height,
    );
    image.dispose();
    return keyed;
  }

  Future<ui.Image> _decodeImageFromPixels(
    Uint8List pixels,
    int width,
    int height,
  ) {
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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 350,
      height: 430,
      child: FutureBuilder<ui.Image>(
        future: _spriteSheet,
        builder: (context, snapshot) {
          final sheet = snapshot.data;
          if (sheet == null) {
            return CustomPaint(painter: _MascotPainter(widget.tick));
          }
          return CustomPaint(
            painter: _YouFaceSpritePainter(
              spriteSheet: sheet,
              ready: widget.ready,
              hasFace: widget.hasFace,
              faceFrame: widget.faceFrame,
              error: widget.error,
              tick: widget.tick,
            ),
          );
        },
      ),
    );
  }
}

class _YouFaceSpritePainter extends CustomPainter {
  _YouFaceSpritePainter({
    required this.spriteSheet,
    required this.ready,
    required this.hasFace,
    required this.tick,
    this.faceFrame,
    this.error,
  });

  static const _frames = <_YouFaceSpriteFrame>[
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(34, 286, 225, 270),
      screen: Rect.fromLTWH(91, 307, 100, 138),
    ),
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(292, 282, 270, 288),
      screen: Rect.fromLTWH(365, 306, 100, 140),
    ),
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(575, 235, 245, 300),
      screen: Rect.fromLTWH(653, 252, 98, 138),
    ),
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(835, 190, 235, 340),
      screen: Rect.fromLTWH(897, 214, 104, 140),
    ),
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(1072, 278, 250, 292),
      screen: Rect.fromLTWH(1140, 296, 100, 138),
    ),
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(1320, 242, 235, 305),
      screen: Rect.fromLTWH(1410, 292, 104, 136),
    ),
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(1545, 405, 265, 175),
      screen: Rect.fromLTWH(1640, 410, 112, 112),
    ),
    _YouFaceSpriteFrame(
      source: Rect.fromLTWH(1810, 282, 245, 275),
      screen: Rect.fromLTWH(1875, 306, 104, 142),
    ),
  ];

  final ui.Image spriteSheet;
  final bool ready;
  final bool hasFace;
  final FaceTextureFrame? faceFrame;
  final String? error;
  final double tick;

  bool get _showFace => ready && hasFace && faceFrame != null && error == null;

  int get _frameIndex {
    if (!_showFace) return 7;
    const sequence = <int>[0, 1, 2, 3, 4, 5, 6, 1];
    return sequence[(tick * sequence.length).floor() % sequence.length];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final frame = _frames[_frameIndex];
    final scale = min(
      size.width * 0.96 / frame.source.width,
      size.height * 0.94 / frame.source.height,
    );
    final drawSize = Size(
      frame.source.width * scale,
      frame.source.height * scale,
    );
    final dst = Rect.fromLTWH(
      (size.width - drawSize.width) / 2,
      size.height - drawSize.height - 6,
      drawSize.width,
      drawSize.height,
    );

    final spritePaint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    canvas.drawImageRect(spriteSheet, frame.source, dst, spritePaint);

    final screenDst = _mapFrameRect(frame.screen, frame.source, dst).deflate(2);
    canvas.save();
    canvas.clipPath(Path()..addOval(screenDst));
    if (_showFace) {
      final texture = faceFrame!.image;
      canvas.drawImageRect(
        texture,
        Rect.fromLTWH(
          0,
          0,
          texture.width.toDouble(),
          texture.height.toDouble(),
        ),
        screenDst,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..isAntiAlias = true,
      );
    } else {
      canvas.translate(screenDst.left, screenDst.top);
      _TvStaticPainter(tick).paint(canvas, screenDst.size);
    }
    canvas.restore();

    final glass = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.0, screenDst.width * 0.035)
      ..color = const Color(0x55071107)
      ..isAntiAlias = true;
    canvas.drawOval(screenDst.inflate(1), glass);
  }

  Rect _mapFrameRect(Rect sourceRect, Rect frameSource, Rect frameDest) {
    final sx = frameDest.width / frameSource.width;
    final sy = frameDest.height / frameSource.height;
    return Rect.fromLTWH(
      frameDest.left + (sourceRect.left - frameSource.left) * sx,
      frameDest.top + (sourceRect.top - frameSource.top) * sy,
      sourceRect.width * sx,
      sourceRect.height * sy,
    );
  }

  @override
  bool shouldRepaint(covariant _YouFaceSpritePainter oldDelegate) =>
      oldDelegate.spriteSheet != spriteSheet ||
      oldDelegate.ready != ready ||
      oldDelegate.hasFace != hasFace ||
      oldDelegate.faceFrame != faceFrame ||
      oldDelegate.error != error ||
      oldDelegate.tick != tick;
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

class _FaceCrop {
  const _FaceCrop({required this.bounds, required this.contourPoints});

  final Rect bounds;
  final List<Offset> contourPoints;
}

class FaceTextureFrame {
  FaceTextureFrame({required this.image});

  final ui.Image image;

  void dispose() => image.dispose();
}

class FaceTexture extends StatelessWidget {
  const FaceTexture({required this.frame, super.key});

  final FaceTextureFrame frame;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FaceTexturePainter(frame),
    );
  }
}

class _FaceTexturePainter extends CustomPainter {
  _FaceTexturePainter(this.frame);

  final FaceTextureFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true;

    canvas.drawOval(dst, Paint()..color = const Color(0xFF25F400));
    canvas.drawImageRect(
      frame.image,
      Rect.fromLTWH(
        0,
        0,
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      ),
      dst,
      paint,
    );

    final vignette = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.transparent,
          Colors.black.withValues(alpha: 0.12),
          Colors.black.withValues(alpha: 0.28),
        ],
        stops: const [0.52, 0.78, 1],
      ).createShader(dst);
    canvas.drawOval(dst, vignette);
  }

  @override
  bool shouldRepaint(covariant _FaceTexturePainter oldDelegate) =>
      oldDelegate.frame != frame;
}

class _NeutralBackdrop extends StatelessWidget {
  const _NeutralBackdrop();

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _NeutralBackdropPainter(),
      );
}

class _NeutralBackdropPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF77D7FF), Color(0xFFB5F38A)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, paint);
    paint.shader = null;

    paint.color = const Color(0x66FFFFFF);
    for (final cloud in const [
      Offset(62, 110),
      Offset(290, 175),
      Offset(170, 300),
    ]) {
      canvas.drawCircle(cloud, 22, paint);
      canvas.drawCircle(cloud + const Offset(26, -8), 28, paint);
      canvas.drawCircle(cloud + const Offset(58, 2), 20, paint);
      canvas.drawRect(
        Rect.fromLTWH(cloud.dx - 6, cloud.dy + 4, 78, 18),
        paint,
      );
    }

    paint
      ..shader = null
      ..color = const Color(0xFF3A9B3E)
      ..style = PaintingStyle.fill;
    final ground = Rect.fromLTWH(0, size.height - 70, size.width, 70);
    canvas.drawRect(ground, paint);
    paint.color = const Color(0xFF2B7C30);
    for (var x = -20.0; x < size.width; x += 36) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(x, size.height - 70),
          width: 62,
          height: 36,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MascotPainter extends CustomPainter {
  _MascotPainter(this.tick);

  final double tick;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF111111)
      ..isAntiAlias = false;

    void rounded(Rect rect, double radius, Color color, {Paint? stroke}) {
      paint.color = color;
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(radius));
      canvas.drawRRect(rr, paint);
      if (stroke != null) canvas.drawRRect(rr, stroke);
    }

    final armSwing = sin(tick * pi * 2) * 5;

    // Braços e luvas.
    outline.strokeWidth = 12;
    canvas.drawArc(
      Rect.fromLTWH(18, 118 + armSwing, 110, 110),
      pi * 0.88,
      pi * 0.76,
      false,
      outline,
    );
    canvas.drawArc(
      Rect.fromLTWH(190, 118 - armSwing, 110, 110),
      pi * 1.36,
      pi * 0.76,
      false,
      outline,
    );
    rounded(
      Rect.fromLTWH(32, 205 + armSwing, 46, 42),
      14,
      const Color(0xFFF5F5F5),
      stroke: outline..strokeWidth = 4,
    );
    rounded(
      Rect.fromLTWH(240, 205 - armSwing, 46, 42),
      14,
      const Color(0xFFF5F5F5),
      stroke: outline..strokeWidth = 4,
    );

    // Pernas e tênis.
    outline.strokeWidth = 13;
    canvas.drawLine(const Offset(118, 315), const Offset(84, 374), outline);
    canvas.drawLine(const Offset(202, 315), const Offset(236, 374), outline);
    rounded(
      const Rect.fromLTWH(46, 360, 72, 34),
      15,
      const Color(0xFF47F010),
      stroke: outline..strokeWidth = 4,
    );
    rounded(
      const Rect.fromLTWH(200, 360, 72, 34),
      15,
      const Color(0xFF47F010),
      stroke: outline..strokeWidth = 4,
    );
    paint.color = Colors.white;
    canvas.drawRect(const Rect.fromLTWH(50, 382, 64, 8), paint);
    canvas.drawRect(const Rect.fromLTWH(204, 382, 64, 8), paint);

    // Corpo/tela estilo aparelho pixel-art.
    rounded(
      const Rect.fromLTWH(64, 28, 190, 312),
      28,
      const Color(0xFF101214),
      stroke: outline..strokeWidth = 7,
    );
    rounded(
      const Rect.fromLTWH(78, 44, 162, 280),
      20,
      const Color(0xFF2F3436),
    );
    rounded(
      const Rect.fromLTWH(88, 58, 142, 210),
      18,
      const Color(0xFF060806),
    );
    paint.color = const Color(0xFF2DFF00);
    canvas.drawOval(const Rect.fromLTWH(94, 68, 130, 180), paint);
    outline
      ..strokeWidth = 5
      ..color = const Color(0xFF071107);
    canvas.drawOval(const Rect.fromLTWH(94, 68, 130, 180), outline);
    outline.color = const Color(0xFF111111);

    // Brilhos do vidro/aro.
    paint.color = const Color(0x66FFFFFF);
    canvas.drawRect(const Rect.fromLTWH(100, 78, 12, 150), paint);
    paint.color = const Color(0x66000000);
    canvas.drawRect(const Rect.fromLTWH(213, 92, 6, 128), paint);

    // Botão inferior.
    paint.color = const Color(0xFF111111);
    canvas.drawCircle(const Offset(159, 296), 17, paint);
    paint.color = const Color(0xFF55FF14);
    canvas.drawCircle(const Offset(159, 296), 10, paint);
  }

  @override
  bool shouldRepaint(covariant _MascotPainter oldDelegate) =>
      oldDelegate.tick != tick;
}

class _TvStaticPainter extends CustomPainter {
  _TvStaticPainter(this.tick);

  final double tick;

  @override
  void paint(Canvas canvas, Size size) {
    final seed = (tick * 100000).floor();
    final rnd = Random(seed);
    final paint = Paint()..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    for (var i = 0; i < 420; i++) {
      final grey = 60 + rnd.nextInt(195);
      paint.color = Color.fromARGB(255, grey, grey, grey);
      final w = 1 + rnd.nextDouble() * 5;
      final h = 1 + rnd.nextDouble() * 4;
      canvas.drawRect(
        Rect.fromLTWH(
          rnd.nextDouble() * size.width,
          rnd.nextDouble() * size.height,
          w,
          h,
        ),
        paint,
      );
    }

    paint.color = const Color(0x6600FF66);
    for (var y = 0.0; y < size.height; y += 9) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1.4), paint);
    }
    paint.color = const Color(0x55FFFFFF);
    final sweepY = (tick * size.height * 1.6) % size.height;
    canvas.drawRect(Rect.fromLTWH(0, sweepY, size.width, 14), paint);
  }

  @override
  bool shouldRepaint(covariant _TvStaticPainter oldDelegate) =>
      oldDelegate.tick != tick;
}
