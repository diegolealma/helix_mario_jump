// Abstração de captura facial. No web usa a ponte MediaPipe; no Android usa
// câmera + ML Kit FaceMesh; nas demais plataformas usa o stub.
export 'face_capture_stub.dart'
    if (dart.library.io) 'face_capture_native.dart'
    if (dart.library.js_interop) 'face_capture_web.dart';
