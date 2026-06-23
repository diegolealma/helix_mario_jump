import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

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
  late final FaceDetector _faceDetector;

  CameraController? _cameraController;
  CameraDescription? _camera;
  bool _detecting = false;
  bool _cameraReady = false;
  String? _cameraError;
  DateTime? _lastFaceSeen;
  FaceTextureFrame? _faceFrame;
  int _faceCount = 0;

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
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableContours: true,
        enableTracking: true,
        minFaceSize: 0.08,
      ),
    );
    unawaited(_initCamera());
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraError = 'Nenhuma câmera encontrada.');
        return;
      }

      _camera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      _cameraController = controller;
      await controller.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
      await controller.startImageStream(_processCameraImage);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = '${e.code}: ${e.description ?? e.code}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = e.toString());
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_detecting) return;
    _detecting = true;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);
      if (!mounted) return;

      final usableFaces = faces.where(_isCredibleFace).toList();
      usableFaces.sort((a, b) {
        final aa = a.boundingBox.width * a.boundingBox.height;
        final bb = b.boundingBox.width * b.boundingBox.height;
        return bb.compareTo(aa);
      });

      final nextFrame = usableFaces.isNotEmpty
          ? await _buildFaceTextureFrame(image, usableFaces.first)
          : null;
      if (!mounted) {
        nextFrame?.dispose();
        return;
      }

      setState(() {
        _faceCount = usableFaces.length;
        if (usableFaces.isNotEmpty) {
          _lastFaceSeen = DateTime.now();
          if (nextFrame != null) {
            final oldFrame = _faceFrame;
            _faceFrame = nextFrame;
            oldFrame?.dispose();
          }
        } else {
          nextFrame?.dispose();
          if (!_hasFreshFace) {
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
    Face face,
  ) async {
    if (!Platform.isAndroid || image.format.group != ImageFormatGroup.nv21) {
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

    final rawContour = _faceContourPoints(face);
    if (rawContour == null || rawContour.length < 8) {
      return null;
    }
    final crop = _pickFaceCrop(rawContour, orientedSize);
    if (crop == null) return null;

    final sourceRect = _stableFaceSourceRect(crop.bounds, orientedSize);
    final contour = crop.contourPoints
        .where((point) => sourceRect.inflate(8).contains(point))
        .toList(growable: false);
    if (contour.length < 8) return null;

    final rawImage = await _decodeRgba(
      orientedFrame.pixels,
      orientedFrame.width,
      orientedFrame.height,
    );
    return FaceTextureFrame(
      image: rawImage,
      sourceRect: sourceRect,
      faceBounds: crop.bounds,
      contourPoints: contour,
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

  List<Offset>? _faceContourPoints(Face face) {
    final points = face.contours[FaceContourType.face]?.points;
    if (points == null || points.length < 8) return null;
    return points
        .map((point) => Offset(point.x.toDouble(), point.y.toDouble()))
        .toList(growable: false);
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

  Rect _stableFaceSourceRect(Rect face, Size rawSize) {
    final center = face.center + Offset(0, -face.height * 0.035);
    final minSource = min(rawSize.width, rawSize.height) * 0.10;
    final maxSource = min(rawSize.width, rawSize.height) * 0.82;
    final width = (face.width * 1.28).clamp(minSource, maxSource);
    final height = max(face.height * 1.34, width * 1.18).clamp(
      minSource,
      maxSource,
    );
    var left = center.dx - width / 2;
    var top = center.dy - height * 0.50;
    left = left.clamp(0.0, max(0.0, rawSize.width - width));
    top = top.clamp(0.0, max(0.0, rawSize.height - height));
    return Rect.fromLTWH(left, top, width, height);
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

  bool _isCredibleFace(Face face) {
    final box = face.boundingBox;
    if (box.width <= 0 || box.height <= 0) return false;
    final ratio = box.width / box.height;
    if (ratio < 0.25 || ratio > 1.85) return false;
    final contourPoints =
        face.contours[FaceContourType.face]?.points.length ?? 0;
    return contourPoints >= 8 && box.width * box.height > 900;
  }

  int? _cameraInputRotationDegrees() {
    final camera = _camera;
    final controller = _cameraController;
    if (camera == null || controller == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    if (Platform.isIOS) return sensorOrientation;
    if (!Platform.isAndroid) return 0;

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
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
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
    final controller = _cameraController;
    if (controller != null && controller.value.isStreamingImages) {
      unawaited(controller.stopImageStream());
    }
    unawaited(controller?.dispose());
    unawaited(_faceDetector.close());
    _faceFrame?.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF6FC4FF),
      body: SafeArea(
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
                        face: _FaceOval(
                          ready: _cameraReady,
                          hasFace: _hasFreshFace,
                          faceFrame: _faceFrame,
                          tick: _clock.value,
                          error: _cameraError,
                        ),
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
                    error: _cameraError,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: Text(
                    'TOQUE NA TELA PARA TESTAR O PULO • SAIA DA CÂMERA PARA VER O CHUVISCO',
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
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.cameraReady,
    required this.hasFace,
    required this.faceCount,
    this.error,
  });

  final bool cameraReady;
  final bool hasFace;
  final int faceCount;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final text = error != null
        ? 'CÂMERA: ERRO'
        : !cameraReady
            ? 'CÂMERA: INICIANDO'
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

class YouFaceMascot extends StatelessWidget {
  const YouFaceMascot({
    required this.face,
    required this.tick,
    super.key,
  });

  final Widget face;
  final double tick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 318,
      height: 430,
      child: CustomPaint(
        painter: _MascotPainter(tick),
        child: Stack(
          children: [
            Positioned(
              left: 96,
              top: 70,
              width: 126,
              height: 174,
              child: ClipOval(child: face),
            ),
          ],
        ),
      ),
    );
  }
}

class _FaceOval extends StatelessWidget {
  const _FaceOval({
    required this.ready,
    required this.hasFace,
    required this.tick,
    this.faceFrame,
    this.error,
  });

  final bool ready;
  final bool hasFace;
  final FaceTextureFrame? faceFrame;
  final double tick;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final showFace = ready && hasFace && faceFrame != null && error == null;

    return ColoredBox(
      color: const Color(0xFF25F400),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showFace) FaceTexture(frame: faceFrame!),
          if (!showFace)
            CustomPaint(
              painter: _TvStaticPainter(tick),
              child: Center(
                child: Text(
                  ready ? 'SEM\nSINAL' : 'CAM\n...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    height: 1.35,
                    fontFamily: 'PressStart2P',
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
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
  FaceTextureFrame({
    required this.image,
    required this.sourceRect,
    required this.faceBounds,
    this.contourPoints,
  });

  final ui.Image image;
  final Rect sourceRect;
  final Rect faceBounds;
  final List<Offset>? contourPoints;

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
    canvas.saveLayer(dst, Paint());
    canvas.drawImageRect(frame.image, frame.sourceRect, dst, paint);

    final mask = Paint()..blendMode = BlendMode.dstIn;
    final contourMask = _contourMaskPath(dst);
    if (contourMask != null) {
      canvas.drawPath(contourMask, mask);
    } else {
      canvas.drawOval(_faceBoundsMaskRect(dst), mask);
    }
    canvas.restore();

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

  Path? _contourMaskPath(Rect dst) {
    final points = frame.contourPoints;
    if (points == null || points.length < 8) return null;

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final x = dst.left +
          ((point.dx - frame.sourceRect.left) / frame.sourceRect.width) *
              dst.width;
      final y = dst.top +
          ((point.dy - frame.sourceRect.top) / frame.sourceRect.height) *
              dst.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return Path.combine(
      PathOperation.intersect,
      Path()..addOval(dst.deflate(1)),
      path,
    );
  }

  Rect _faceBoundsMaskRect(Rect dst) {
    final face = frame.faceBounds;
    final left = dst.left +
        ((face.left - frame.sourceRect.left) / frame.sourceRect.width) *
            dst.width;
    final top = dst.top +
        ((face.top - frame.sourceRect.top) / frame.sourceRect.height) *
            dst.height;
    final right = dst.left +
        ((face.right - frame.sourceRect.left) / frame.sourceRect.width) *
            dst.width;
    final bottom = dst.top +
        ((face.bottom - frame.sourceRect.top) / frame.sourceRect.height) *
            dst.height;
    return Rect.fromLTRB(left, top, right, bottom)
        .inflate(min(dst.width, dst.height) * 0.035)
        .intersect(dst.deflate(1));
  }
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
