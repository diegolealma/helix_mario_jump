import 'dart:async';

import 'package:flame_audio/flame_audio.dart';
import 'package:flutter/foundation.dart';

/// Camada de áudio do jogo, baseada em [AudioPool].
///
/// Por que pools? `FlameAudio.play` cria um `AudioPlayer` (e, no web, um
/// `AudioContext`) NOVO a cada chamada e não o fecha — eles acumulam, batem no
/// limite do navegador e geram atraso crescente, pior ainda com sons em rajada.
/// Um [AudioPool] mantém um punhado de players pré-carregados e reutilizáveis:
/// tocar é só "resume" (latência mínima) e o player volta para o pool depois,
/// então o número de contextos fica fixo.
///
/// Os WAVs ficam em `assets/audio/` (prefix padrão do flame_audio). No web a URL
/// final vira `assets/assets/audio/<arquivo>`, que é onde a produção os serve.
class GameAudio {
  GameAudio._();

  static bool muted = false;

  static const jump = 'jump.wav';
  static const coin = 'coin.wav';
  static const stomp = 'stomp.wav';
  static const brick = 'brick.wav';
  static const powerup = 'powerup.wav';
  static const star = 'star.wav';
  static const hurt = 'hurt.wav';
  static const death = 'death.wav';
  static const gameover = 'gameover.wav';
  static const start = 'start.wav';
  static const fever = 'fever.wav';

  /// Quantos players simultâneos cada som pode ter. Sons que disparam em
  /// rajada (pulo, moeda) precisam de mais; sons únicos bastam com 1.
  static const _maxPlayers = <String, int>{
    jump: 4,
    coin: 3,
    stomp: 2,
    brick: 2,
    fever: 2,
    hurt: 2,
    powerup: 1,
    star: 1,
    death: 1,
    gameover: 1,
    start: 1,
  };

  static final Map<String, AudioPool> _pools = {};

  /// Cria os pools (pré-carrega 1 player por som). Best-effort: falha em um som
  /// não impede os outros.
  static Future<void> load() async {
    for (final entry in _maxPlayers.entries) {
      try {
        _pools[entry.key] = await FlameAudio.createPool(
          entry.key,
          minPlayers: 1,
          maxPlayers: entry.value,
        );
      } catch (e) {
        debugPrint('GameAudio: falha ao criar pool ${entry.key}: $e');
      }
    }
  }

  /// Toca um efeito reutilizando um player do pool (fire-and-forget).
  static void play(String name, {double volume = 1.0}) {
    if (muted) return;
    final pool = _pools[name];
    if (pool == null) return;
    unawaited(_safeStart(pool, name, volume));
  }

  static Future<void> _safeStart(
      AudioPool pool, String name, double volume) async {
    try {
      await pool.start(volume: volume);
    } catch (e) {
      debugPrint('GameAudio: falha ao tocar $name: $e');
    }
  }

  static void toggleMute() => muted = !muted;
}
