import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:shared_preferences/shared_preferences.dart';

import 'model.dart';
import 'render.dart';
import 'sprites.dart';

enum GState { loading, title, playing, dying, gameOver }

/// Resolução virtual de projeto (retrato, pensado para mobile).
const designW = 480.0;
const designH = 854.0;

class SuperHelixGame extends FlameGame with KeyboardEvents {
  // --- Física ---
  static const gravity = 2600.0;
  static const maxFall = 1500.0;
  static const bounceV = 830.0;
  static const playerOrbitR = 105.0;
  static const tilt = 0.30; // achatamento da elipse (pseudo-3D)

  final sprites = Sprites();
  SharedPreferences? _prefs;

  GState state = GState.loading;
  double stateT = 0;
  double time = 0;

  late Tower tower;
  double rot = 0; // rotação da torre (rad)
  int _keyDir = 0; // -1 esquerda, 1 direita (setas/A-D)

  // Jogador
  double py = 0; // Y do mundo (pés do personagem); cresce para baixo
  double vy = 0;
  bool superForm = false;
  double starT = 0; // tempo restante de estrela
  double invulnT = 0; // invencibilidade pós-dano
  double lastBounceT = -10;
  int passStreak = 0; // andares atravessados sem quicar (>=3 => modo fogo)

  // Câmera
  double camY = 0;
  double shakeT = 0;

  // Pontuação
  int score = 0;
  int coins = 0;
  int depth = 0; // andar mais fundo alcançado
  int best = 0;
  bool newBest = false;

  final particles = <Particle>[];
  final floatTexts = <FloatText>[];

  late final Renderer renderer = Renderer(this);
  final _rng = Random();

  bool get fever => passStreak >= 3;

  @override
  Future<void> onLoad() async {
    await sprites.load();
    _prefs = await SharedPreferences.getInstance();
    best = _prefs?.getInt('best') ?? 0;
    _reset();
    state = GState.title;
    add(_ScenePainter());
  }

  void _reset() {
    tower = Tower(_rng.nextInt(1 << 30));
    tower.ensureFloors(14);
    rot = 0;
    py = Tower.firstY - 60;
    vy = 0;
    superForm = false;
    starT = 0;
    invulnT = 0;
    passStreak = 0;
    camY = py - 300;
    shakeT = 0;
    score = 0;
    coins = 0;
    depth = 0;
    newBest = false;
    particles.clear();
    floatTexts.clear();
    stateT = 0;
  }

  // ----------------------------------------------------------- entrada

  /// Arrasto horizontal (em pixels físicos) gira a torre.
  void onDragDx(double dx) {
    if (state == GState.playing || state == GState.title) {
      final scale = min(size.x / designW, size.y / designH);
      rot += dx / max(scale, 0.001) * (3.6 / designW);
    }
  }

  void onTapScreen() {
    switch (state) {
      case GState.title:
        _reset();
        state = GState.playing;
      case GState.gameOver:
        if (stateT > 0.6) {
          _reset();
          state = GState.playing;
        }
      default:
        break;
    }
  }

  @override
  KeyEventResult onKeyEvent(
      KeyEvent event, Set<LogicalKeyboardKey> keysPressed) {
    _keyDir = 0;
    if (keysPressed.contains(LogicalKeyboardKey.arrowLeft) ||
        keysPressed.contains(LogicalKeyboardKey.keyA)) {
      _keyDir -= 1;
    }
    if (keysPressed.contains(LogicalKeyboardKey.arrowRight) ||
        keysPressed.contains(LogicalKeyboardKey.keyD)) {
      _keyDir += 1;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      onTapScreen();
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------- update

  @override
  void update(double dt) {
    super.update(dt);
    if (state == GState.loading) return;
    final clamped = min(dt, 1 / 20);
    time += clamped;
    stateT += clamped;
    _updateParticles(clamped);

    switch (state) {
      case GState.title:
        rot += 0.35 * clamped;
        _demoBounce(clamped);
      case GState.playing:
        _updatePlaying(clamped);
      case GState.dying:
        vy += gravity * clamped;
        py += vy * clamped;
        if (py - camY > designH + 260 || stateT > 3) _finishDeath();
      default:
        break;
    }
  }

  void _demoBounce(double dt) {
    final floorY = Tower.floorY(0);
    vy += gravity * dt;
    py += vy * dt;
    if (vy > 0 && py >= floorY) {
      py = floorY;
      vy = -bounceV;
      lastBounceT = time;
    }
  }

  void _updatePlaying(double dt) {
    rot += _keyDir * 3.0 * dt;
    starT = max(0, starT - dt);
    invulnT = max(0, invulnT - dt);
    shakeT = max(0, shakeT - dt);

    // Inimigos patrulham.
    for (final f in _visibleFloors()) {
      for (final e in f.enemies) {
        if (!e.dead) e.update(dt);
      }
    }

    vy = min(vy + gravity * dt, maxFall);
    var newY = py + vy * dt;

    if (vy > 0) {
      // Verifica andares cruzados nesta etapa.
      var i = max(0, ((py - Tower.firstY) / Tower.floorSpacing).ceil());
      tower.ensureFloors(i + 16);
      while (Tower.floorY(i) <= newY) {
        final floor = tower.floors[i];
        final top = floor.y;
        if (top > py && !floor.broken) {
          final landed = _resolveFloor(floor);
          if (landed) {
            newY = top;
            break;
          }
        }
        i++;
        tower.ensureFloors(i + 16);
      }
    }
    py = newY;

    _collectItems();

    // Câmera persegue o jogador (apenas descendo).
    final target = py - 300;
    if (target > camY) {
      camY += (target - camY) * min(1, dt * 12);
    }
    if (py - camY > 430) camY = py - 430;
  }

  /// Retorna true se o jogador parou (quicou) neste andar.
  bool _resolveFloor(Floor floor) {
    final local = _localTheta();

    // Estrela: atravessa tudo quebrando.
    if (starT > 0) {
      _breakFloor(floor);
      _passFloor(floor);
      return false;
    }

    final seg = floor.segAt(local);
    if (seg == SegType.gap) {
      passStreak++;
      _passFloor(floor);
      return false;
    }

    // Modo fogo: quebra a próxima plataforma e continua caindo.
    if (fever) {
      _breakFloor(floor);
      _passFloor(floor);
      passStreak = 0;
      return false;
    }

    // Inimigo embaixo do jogador?
    for (final e in floor.enemies) {
      if (e.dead) continue;
      if (_angDiff(e.theta, local).abs() < 0.30) {
        if (e.kind == EnemyKind.walker || invulnT > 0) {
          _stomp(floor, e);
          return true;
        }
        // Espinhoso: dói pisar.
        if (_damage(floor)) return true; // sobreviveu, quicou
        return false; // morreu
      }
    }

    if (seg == SegType.danger) {
      if (invulnT > 0) {
        _bounce(floor);
        return true;
      }
      if (_damage(floor)) return true;
      return false;
    }

    _bounce(floor);
    return true;
  }

  double _localTheta() => ((-rot) % (2 * pi) + 2 * pi) % (2 * pi);

  double _angDiff(double a, double b) {
    final d = (a - b) % (2 * pi);
    return d > pi ? d - 2 * pi : (d < -pi ? d + 2 * pi : d);
  }

  void _bounce(Floor floor, {double boost = 1}) {
    py = floor.y;
    vy = -bounceV * boost;
    lastBounceT = time;
    passStreak = 0;
    renderer.spawnDust(floor.y);
  }

  void _passFloor(Floor floor) {
    final gained = 15 + passStreak * 5;
    score += gained;
    if (floor.index + 1 > depth) depth = floor.index + 1;
  }

  void _breakFloor(Floor floor) {
    if (floor.broken) return;
    floor.broken = true;
    score += 300;
    shakeT = 0.32;
    renderer.spawnDebris(floor);
    for (final e in floor.enemies) {
      if (!e.dead) {
        e.dead = true;
        score += 100;
      }
    }
    renderer.spawnFloatText(floor.y - 40, '+300');
  }

  void _stomp(Floor floor, Enemy e) {
    e.dead = true;
    score += 200;
    renderer.spawnStompPoof(floor, e);
    renderer.spawnFloatText(floor.y - 60, '+200');
    _bounce(floor, boost: 1.12);
  }

  /// Aplica dano. Retorna true se o jogador sobreviveu.
  bool _damage(Floor floor) {
    if (superForm) {
      superForm = false;
      invulnT = 2.5;
      _bounce(floor);
      return true;
    }
    _die();
    return false;
  }

  void _die() {
    state = GState.dying;
    stateT = 0;
    vy = -750;
  }

  void _finishDeath() {
    if (score > best) {
      best = score;
      newBest = true;
      _prefs?.setInt('best', best);
    }
    state = GState.gameOver;
    stateT = 0;
  }

  void _collectItems() {
    final local = _localTheta();
    final iMid = ((py - Tower.firstY) / Tower.floorSpacing).round();
    for (var i = max(0, iMid - 1); i <= iMid + 1; i++) {
      if (i >= tower.floors.length) break;
      final floor = tower.floors[i];
      for (final item in floor.items) {
        if (item.taken) continue;
        final itemY = floor.y - 58;
        if ((itemY - py).abs() > 40) continue;
        if (_angDiff(item.theta, local).abs() > 0.32) continue;
        item.taken = true;
        switch (item.kind) {
          case ItemKind.coin:
            coins++;
            score += 100;
            renderer.spawnSparkle(itemY);
            renderer.spawnFloatText(itemY - 20, '+100');
          case ItemKind.mushroom:
            if (superForm) {
              score += 500;
              renderer.spawnFloatText(itemY - 20, '+500');
            } else {
              superForm = true;
              renderer.spawnFloatText(itemY - 20, 'SUPER!');
            }
            renderer.spawnSparkle(itemY);
          case ItemKind.star:
            starT = 8;
            renderer.spawnFloatText(itemY - 20, 'ESTRELA!');
            renderer.spawnSparkle(itemY);
        }
      }
    }
  }

  Iterable<Floor> _visibleFloors() sync* {
    for (final f in tower.floors) {
      final sy = f.y - camY;
      if (sy < -260) continue;
      if (sy > designH + 220) break;
      yield f;
    }
  }

  List<Floor> visibleFloors() => _visibleFloors().toList();

  void _updateParticles(double dt) {
    particles.removeWhere((p) => !p.update(dt));
    floatTexts.removeWhere((t) => !t.update(dt));
  }
}

/// Componente único que desenha toda a cena (mundo + HUD) no canvas.
class _ScenePainter extends Component with HasGameReference<SuperHelixGame> {
  @override
  void render(Canvas canvas) {
    game.renderer.render(canvas, game.size);
  }
}
