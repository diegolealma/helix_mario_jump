import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' as ui;

/// Visão tipada do objeto `window.youfaceCapture` criado por `web/face_capture.js`.
@JS('youfaceCapture')
external _JsCapture? get _jsCapture;

extension type _JsCapture(JSObject _) implements JSObject {
  external JSPromise<JSAny?> start();
  external void stop();
  external String get status;
  external String? get errorMessage;
  external bool get hasFace;
  external int get frameId;
  external int get texSize;
  external JSUint8Array getFrameBytes();
}

/// Captura facial no Flutter Web via MediaPipe FaceMesh (ponte JS).
///
/// O JS faz detecção + recorte oval e mantém a textura pronta num canvas; aqui
/// só puxamos os bytes RGBA quando há um frame novo e os transformamos em
/// [ui.Image] para o pintor do mascote.
class WebFaceCapture {
  int _lastDecodedFrame = -1;

  bool get isSupported => _jsCapture != null;

  String get status => _jsCapture?.status ?? 'unavailable';

  String? get errorMessage => _jsCapture?.errorMessage;

  bool get hasFace => _jsCapture?.hasFace ?? false;

  Future<void> start() async {
    final cap = _jsCapture;
    if (cap == null) return;
    await cap.start().toDart;
  }

  void stop() => _jsCapture?.stop();

  /// Retorna uma nova [ui.Image] do rosto se houver frame inédito; senão null.
  Future<ui.Image?> takeFrameIfNew() async {
    final cap = _jsCapture;
    if (cap == null || !cap.hasFace) return null;
    final id = cap.frameId;
    if (id == _lastDecodedFrame) return null;
    _lastDecodedFrame = id;

    final size = cap.texSize;
    final bytes = cap.getFrameBytes().toDart;
    if (bytes.length < size * size * 4) return null;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
