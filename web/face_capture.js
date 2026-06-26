// Ponte de captura facial para Flutter Web.
//
// Porta o pipeline comprovado do projeto face3d: abre a câmera, roda o
// MediaPipe FaceMesh (JS/WASM, que funciona no navegador — ao contrário do
// ML Kit nativo) e constrói a textura oval do rosto (512x512, espelhada) num
// canvas offscreen. O Dart lê os pixels prontos via `getFrameBytes()` e os
// transforma em `ui.Image`.
//
// API exposta em `window.youfaceCapture`:
//   start()         -> Promise<void>   inicia câmera + detecção
//   stop()          -> void            encerra stream e loop
//   status          -> 'idle'|'starting'|'live'|'error'
//   errorMessage    -> string|null     mensagem amigável de erro
//   hasFace         -> bool            há rosto fresco no último frame
//   frameId         -> int             incrementa a cada textura nova
//   texSize         -> int             512
//   getFrameBytes() -> Uint8Array      RGBA da textura (texSize*texSize*4)

(function () {
  'use strict';

  const TEX_SIZE = 512;
  const SMOOTHING = 0.4;
  const BRIGHTNESS = 1.0;
  // Quanto a face é ampliada para preencher o oval da telinha. 1.0 = recorte
  // justo do rosto (sobra borda); ~1.45 faz a face cobrir/transbordar o oval,
  // sem moldura. Aumente para mais zoom, diminua para mostrar o rosto inteiro.
  const FACE_FILL = 1.45;

  // Contorno do rosto (face oval) — mesmos índices do MediaPipe FaceMesh.
  const FACE_OVAL_IDX = [
    10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379,
    378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
    162, 21, 54, 103, 67, 109,
  ];

  const faceCanvas = document.createElement('canvas');
  faceCanvas.width = TEX_SIZE;
  faceCanvas.height = TEX_SIZE;
  const faceCtx = faceCanvas.getContext('2d', { willReadFrequently: true });

  const videoEl = document.createElement('video');
  videoEl.autoplay = true;
  videoEl.playsInline = true;
  videoEl.muted = true;
  videoEl.setAttribute('playsinline', '');
  videoEl.setAttribute('muted', '');

  // Mantém o <video> anexado ao DOM (invisível). Alguns navegadores só tocam o
  // stream de forma confiável quando o elemento está na árvore do documento.
  function ensureVideoAttached() {
    if (videoEl.isConnected) return;
    videoEl.style.cssText =
      'position:fixed;left:-10px;top:-10px;width:2px;height:2px;opacity:0;pointer-events:none;';
    (document.body || document.documentElement).appendChild(videoEl);
  }

  const delay = (ms) => new Promise((r) => setTimeout(r, ms));

  const state = {
    status: 'idle',
    errorMessage: null,
    hasFace: false,
    frameId: 0,
    latestBytes: new Uint8Array(TEX_SIZE * TEX_SIZE * 4),
    bboxSmooth: null,
    lastFaceTime: 0,
    cameraStream: null,
    faceMesh: null,
    detectionRunning: false,
    rafId: 0,
    starting: null,
    autoRetries: 0,
    autoRetryTimer: 0,
    cameraCount: -1,
  };

  function log(level, event, data) {
    try {
      // Embute os dados na própria string: o terminal do `flutter run` só mostra
      // o primeiro argumento do console, então JSON.stringify garante que count,
      // nome do erro etc. apareçam lá.
      const suffix = data === undefined ? '' : ' ' + JSON.stringify(data);
      const msg = `[youface] ${event}${suffix}`;
      // eslint-disable-next-line no-console
      console[level === 'error' ? 'error' : level === 'warn' ? 'warn' : 'log'](msg);
    } catch (_) {
      // ignore
    }
  }

  function cameraErrorMessage(err) {
    if (err && err.name === 'NotReadableError') {
      return 'NotReadableError: câmera ocupada. Feche Zoom/Teams/Câmera do Windows e recarregue.';
    }
    if (err && err.name === 'NotAllowedError') {
      return 'NotAllowedError: permissão de câmera negada no navegador.';
    }
    if (err && err.name === 'NotFoundError') {
      return 'NotFoundError: nenhuma câmera encontrada.';
    }
    return 'Erro: ' + ((err && err.message) || 'câmera indisponível');
  }

  async function enumerateCameras() {
    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
        return [];
      }
      const devices = await navigator.mediaDevices.enumerateDevices();
      return devices.filter((d) => d.kind === 'videoinput');
    } catch (_) {
      return [];
    }
  }

  function isVirtualCam(label) {
    return /\b(obs|virtual|droidcam|manycam|snap camera|xsplit|ndi)\b/i.test(
      label || ''
    );
  }

  async function getCameraStream(cams) {
    // Monta a lista de tentativas: câmera "user" padrão, depois CADA dispositivo
    // específico (físicas reais antes das virtuais), e por fim "qualquer".
    const attempts = [
      {
        label: 'facingMode user',
        constraints: {
          video: { width: { ideal: 640 }, height: { ideal: 480 }, facingMode: 'user' },
          audio: false,
        },
      },
    ];
    const ordered = (cams || []).slice().sort((a, b) => {
      // Câmeras físicas reais primeiro; virtuais (OBS etc.) por último.
      return (isVirtualCam(a.label) ? 1 : 0) - (isVirtualCam(b.label) ? 1 : 0);
    });
    for (const cam of ordered) {
      if (!cam.deviceId) continue;
      attempts.push({
        label: cam.label || cam.deviceId,
        constraints: {
          video: { deviceId: { exact: cam.deviceId } },
          audio: false,
        },
      });
    }
    attempts.push({
      label: 'qualquer',
      constraints: { video: true, audio: false },
    });

    let lastError = null;
    for (let i = 0; i < attempts.length; i++) {
      try {
        const stream = await navigator.mediaDevices.getUserMedia(
          attempts[i].constraints
        );
        log('info', 'camera-ok', { device: attempts[i].label });
        return stream;
      } catch (err) {
        lastError = err;
        log('warn', 'camera-attempt-failed', {
          attempt: i + 1,
          device: attempts[i].label,
          name: err && err.name,
        });
        // Permissão negada: não adianta tentar outros dispositivos.
        if (err && err.name === 'NotAllowedError') throw err;
        // Câmera ocupada/instável: espera um pouco antes da próxima tentativa.
        await delay(200);
      }
    }
    throw lastError || new Error('sem câmera');
  }

  function texturePoint(lm, minX, minY, maxX, maxY) {
    const cropW = Math.max(0.0001, maxX - minX);
    const cropH = Math.max(0.0001, maxY - minY);
    const u = (lm.x - minX) / cropW;
    const v = (lm.y - minY) / cropH;
    return {
      x: Math.max(0, Math.min(TEX_SIZE, (1 - u) * TEX_SIZE)),
      y: Math.max(0, Math.min(TEX_SIZE, v * TEX_SIZE)),
    };
  }

  function traceOvalPath(ctx, landmarks, minX, minY, maxX, maxY, scale) {
    const cx = TEX_SIZE / 2;
    const cy = TEX_SIZE / 2;
    let started = false;
    for (const idx of FACE_OVAL_IDX) {
      const lm = landmarks[idx];
      if (!lm) continue;
      const p = texturePoint(lm, minX, minY, maxX, maxY);
      const x = cx + (p.x - cx) * scale;
      const y = cy + (p.y - cy) * scale;
      if (!started) {
        ctx.moveTo(x, y);
        started = true;
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.closePath();
  }

  function buildFaceTexture(landmarks, minX, minY, maxX, maxY) {
    faceCtx.save();
    // Fundo transparente: fora do rosto não pinta nada (sem moldura marrom).
    faceCtx.clearRect(0, 0, TEX_SIZE, TEX_SIZE);

    // Recorta no contorno do rosto (tira camisa/fundo), ampliado por FACE_FILL
    // em torno do centro para a face cobrir/transbordar o oval da telinha.
    faceCtx.beginPath();
    traceOvalPath(faceCtx, landmarks, minX, minY, maxX, maxY, FACE_FILL);
    faceCtx.clip();

    // Mesma ampliação aplicada ao vídeo, em torno do centro, + espelho selfie.
    faceCtx.translate(TEX_SIZE / 2, TEX_SIZE / 2);
    faceCtx.scale(FACE_FILL, FACE_FILL);
    faceCtx.translate(-TEX_SIZE / 2, -TEX_SIZE / 2);
    faceCtx.scale(-1, 1);
    faceCtx.translate(-TEX_SIZE, 0);

    const sx = minX * videoEl.videoWidth;
    const sy = minY * videoEl.videoHeight;
    const sw = (maxX - minX) * videoEl.videoWidth;
    const sh = (maxY - minY) * videoEl.videoHeight;

    faceCtx.filter = `brightness(${BRIGHTNESS}) contrast(1.06) saturate(1.08)`;
    faceCtx.drawImage(videoEl, sx, sy, sw, sh, 0, 0, TEX_SIZE, TEX_SIZE);
    faceCtx.filter = 'none';
    faceCtx.restore();

    const data = faceCtx.getImageData(0, 0, TEX_SIZE, TEX_SIZE).data;
    state.latestBytes = new Uint8Array(data.buffer.slice(0));
    state.frameId++;
  }

  function onFaceResults(results) {
    const faces = results && results.multiFaceLandmarks;
    if (!faces || faces.length === 0) {
      // Mantém o último rosto por 850ms para evitar piscadas.
      if (performance.now() - state.lastFaceTime > 850) {
        state.hasFace = false;
        state.bboxSmooth = null;
      }
      return;
    }

    const landmarks = faces[0];
    let minX = 1;
    let minY = 1;
    let maxX = 0;
    let maxY = 0;
    for (const idx of FACE_OVAL_IDX) {
      const lm = landmarks[idx];
      if (!lm) continue;
      minX = Math.min(minX, lm.x);
      minY = Math.min(minY, lm.y);
      maxX = Math.max(maxX, lm.x);
      maxY = Math.max(maxY, lm.y);
    }

    const padX = (maxX - minX) * 0.06;
    const padY = (maxY - minY) * 0.08;
    minX -= padX;
    maxX += padX;
    minY -= padY;
    maxY += padY;

    // Quadrado em torno do centro.
    const cx = (minX + maxX) / 2;
    const cy = (minY + maxY) / 2;
    const size = Math.max(maxX - minX, maxY - minY);
    minX = cx - size / 2;
    minY = cy - size / 2;
    maxX = cx + size / 2;
    maxY = cy + size / 2;

    minX = Math.max(0, Math.min(1, minX));
    minY = Math.max(0, Math.min(1, minY));
    maxX = Math.max(0, Math.min(1, maxX));
    maxY = Math.max(0, Math.min(1, maxY));

    if (state.bboxSmooth) {
      const s = SMOOTHING;
      minX = state.bboxSmooth.minX * s + minX * (1 - s);
      minY = state.bboxSmooth.minY * s + minY * (1 - s);
      maxX = state.bboxSmooth.maxX * s + maxX * (1 - s);
      maxY = state.bboxSmooth.maxY * s + maxY * (1 - s);
    }
    state.bboxSmooth = { minX, minY, maxX, maxY };

    buildFaceTexture(landmarks, minX, minY, maxX, maxY);
    state.hasFace = true;
    state.lastFaceTime = performance.now();
  }

  async function processFrame() {
    if (!state.detectionRunning || !state.faceMesh) return;
    if (videoEl.readyState >= 2 && videoEl.videoWidth > 0) {
      try {
        await state.faceMesh.send({ image: videoEl });
      } catch (e) {
        log('warn', 'detection-error', { message: e && e.message });
      }
    }
    if (state.detectionRunning) {
      state.rafId = requestAnimationFrame(processFrame);
    }
  }

  function initFaceMesh() {
    if (typeof FaceMesh === 'undefined') {
      state.status = 'error';
      state.errorMessage = 'MediaPipe FaceMesh não carregou (CDN bloqueado?).';
      log('error', 'mediapipe-not-loaded');
      return false;
    }
    state.faceMesh = new FaceMesh({
      locateFile: (file) =>
        `https://cdn.jsdelivr.net/npm/@mediapipe/face_mesh/${file}`,
    });
    state.faceMesh.setOptions({
      maxNumFaces: 1,
      refineLandmarks: false,
      minDetectionConfidence: 0.5,
      minTrackingConfidence: 0.5,
    });
    state.faceMesh.onResults(onFaceResults);
    state.detectionRunning = true;
    processFrame();
    return true;
  }

  function scheduleAutoRetry() {
    if (state.autoRetryTimer) clearTimeout(state.autoRetryTimer);
    if (state.autoRetries >= 30) return; // ~1 min de tentativas
    state.autoRetries++;
    state.autoRetryTimer = setTimeout(() => {
      if (state.status !== 'live') start(true);
    }, 2000);
  }

  async function start(isAutoRetry) {
    if (state.status === 'live') return Promise.resolve();
    if (state.status === 'starting' && !isAutoRetry) {
      return state.starting || Promise.resolve();
    }
    if (!isAutoRetry) state.autoRetries = 0; // toque/gesto: reinicia o contador
    if (state.autoRetryTimer) {
      clearTimeout(state.autoRetryTimer);
      state.autoRetryTimer = 0;
    }
    state.status = 'starting';
    state.errorMessage = null;

    state.starting = (async () => {
      try {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          throw new Error('getUserMedia indisponível neste navegador.');
        }
        ensureVideoAttached();

        const camsBefore = await enumerateCameras();
        state.cameraCount = camsBefore.length;
        // Contagem no NOME do evento: o terminal do `flutter run` só imprime o
        // nome, então `cameras-1` / `cameras-0` chega lá de forma confiável.
        log('info', 'cameras-' + camsBefore.length);
        log('info', 'cameras-found', {
          count: camsBefore.length,
          labels: camsBefore.map((c) => c.label || '(sem rótulo)'),
        });

        // Solta qualquer stream anterior antes de pedir de novo.
        stopStreamOnly();
        state.cameraStream = await getCameraStream(camsBefore);
        videoEl.srcObject = state.cameraStream;
        await videoEl.play();
        if (!initFaceMesh()) return;
        state.status = 'live';
        state.autoRetries = 0;
        log('info', 'capture-live', {
          w: videoEl.videoWidth,
          h: videoEl.videoHeight,
        });
      } catch (err) {
        state.status = 'error';
        const name = (err && err.name) || 'Error';
        state.errorMessage =
          `${cameraErrorMessage(err)} [${name} · ${state.cameraCount} cam` +
          `${state.autoRetries > 0 ? ' · retry ' + state.autoRetries : ''}]`;
        // Nome do erro no NOME do evento (ex.: `err-NotReadableError`).
        log('error', 'err-' + name);
        log('error', 'start-failed', { name: name, cameras: state.cameraCount });
        // Câmera ocupada costuma liberar quando o outro app/aba fecha:
        // tenta de novo sozinho até lá.
        if (err && err.name === 'NotReadableError') {
          scheduleAutoRetry();
        }
      }
    })();
    return state.starting;
  }

  function stopStreamOnly() {
    if (state.cameraStream) {
      for (const track of state.cameraStream.getTracks()) track.stop();
      state.cameraStream = null;
    }
  }

  function stop() {
    state.detectionRunning = false;
    if (state.rafId) cancelAnimationFrame(state.rafId);
    if (state.autoRetryTimer) {
      clearTimeout(state.autoRetryTimer);
      state.autoRetryTimer = 0;
    }
    stopStreamOnly();
    if (state.faceMesh && state.faceMesh.close) {
      try {
        state.faceMesh.close();
      } catch (_) {
        // ignore
      }
    }
    state.faceMesh = null;
    state.hasFace = false;
    state.status = 'idle';
  }

  window.youfaceCapture = {
    start,
    stop,
    get status() {
      return state.status;
    },
    get errorMessage() {
      return state.errorMessage;
    },
    get hasFace() {
      return state.hasFace;
    },
    get frameId() {
      return state.frameId;
    },
    get texSize() {
      return TEX_SIZE;
    },
    getFrameBytes() {
      return state.latestBytes;
    },
  };

  // Marcador de versão: se você vê `bridge-ready-v6` no terminal, o código novo
  // está ativo (não é cache).
  log('info', 'bridge-ready-v6');
})();
