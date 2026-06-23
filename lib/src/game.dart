import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:shared_preferences/shared_preferences.dart';

import 'audio.dart';
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
  static const airJumpV = 900.0;
  static const spinDiveV = 1180.0;
  static const doubleTapWindow = 0.34;
  static const swipeThreshold = 42.0;
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
  bool firePower = false;
  bool spinDive = false;
  double spinAngle = 0;
  double starT = 0; // tempo restante de estrela
  double fireCooldown = 0;
  double invulnT = 0; // invencibilidade pós-dano
  double lastBounceT = -10;
  int passStreak = 0; // andares atravessados sem quicar (>=3 => modo fogo)
  bool _airJumpUsed = true;
  double _lastPlayTapT = -10;
  bool _safeLandingAfterStar = false;
  Offset _dragTotal = Offset.zero;
  bool _dragActionTriggered = false;

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
  final fireShots = <FireShot>[];

  late final Renderer renderer = Renderer(this);
  final _rng = Random();

  bool get fever => passStreak >= 3;

  @override
  Future<void> onLoad() async {
    await sprites.load();
    await GameAudio.load();
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
    firePower = false;
    spinDive = false;
    spinAngle = 0;
    starT = 0;
    fireCooldown = 0;
    invulnT = 0;
    passStreak = 0;
    _airJumpUsed = true;
    _lastPlayTapT = -10;
    _safeLandingAfterStar = false;
    _dragTotal = Offset.zero;
    _dragActionTriggered = false;
    camY = py - 300;
    shakeT = 0;
    score = 0;
    coins = 0;
    depth = 0;
    newBest = false;
    particles.clear();
    floatTexts.clear();
    fireShots.clear();
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

  void onDragStart() {
    _dragTotal = Offset.zero;
    _dragActionTriggered = false;
  }

  void onDragUpdate(double dx, double dy) {
    if (dx != 0) onDragDx(dx);
    if (state != GState.playing || _dragActionTriggered) return;

    _dragTotal += Offset(dx, dy);
    final vertical = _dragTotal.dy.abs();
    final horizontal = _dragTotal.dx.abs();
    if (vertical < swipeThreshold || vertical < horizontal * 1.25) return;

    _dragActionTriggered = true;
    if (_dragTotal.dy > 0) {
      _startSpinDive();
    } else {
      _shootFire();
    }
  }

  void onDragEnd() {
    _dragTotal = Offset.zero;
    _dragActionTriggered = false;
  }

  void _startSpinDive() {
    final airborne = time - lastBounceT > 0.06;
    if (state != GState.playing || !airborne || spinDive) return;
    spinDive = true;
    vy = max(vy, spinDiveV);
    _airJumpUsed = true;
    _lastPlayTapT = -10;
  }

  void _shootFire() {
    if (state != GState.playing || !firePower || fireCooldown > 0) return;
    final theta = _localTheta();
    final y = py - _playerHeight * 0.45;
    fireShots
      ..add(FireShot(theta: theta - 0.08, y: y, angularV: -4.8))
      ..add(FireShot(theta: theta + 0.08, y: y, angularV: 4.8));
    fireCooldown = 0.45;
    renderer.spawnFireBurst(y);
  }

  void onTapScreen() {
    switch (state) {
      case GState.title:
        _reset();
        state = GState.playing;
        GameAudio.play(GameAudio.start);
      case GState.gameOver:
        if (stateT > 0.6) {
          _reset();
          state = GState.playing;
          GameAudio.play(GameAudio.start);
        }
      case GState.playing:
        final sinceLastTap = time - _lastPlayTapT;
        final hasLeftFloor = time - lastBounceT > 0.06;
        if (sinceLastTap <= doubleTapWindow && hasLeftFloor && !_airJumpUsed) {
          vy = -airJumpV;
          _airJumpUsed = true;
          _lastPlayTapT = -10;
        } else {
          _lastPlayTapT = time;
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
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyM) {
      GameAudio.toggleMute();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _startSpinDive();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _shootFire();
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
    final hadStar = starT > 0;
    starT = max(0, starT - dt);
    fireCooldown = max(0, fireCooldown - dt);
    if (spinDive) spinAngle += 14 * dt;
    if (hadStar && starT == 0) {
      _safeLandingAfterStar = true;
      passStreak = 0;
    }
    invulnT = max(0, invulnT - dt);
    shakeT = max(0, shakeT - dt);

    // Inimigos, cascos e bolas de fogo.
    final visible = _visibleFloors().toList();
    for (final f in visible) {
      for (final e in f.enemies) {
        if (!e.dead) e.update(dt);
      }
      _resolveShellHits(f);
    }
    fireShots.removeWhere((shot) => !shot.update(dt));
    _resolveFireHits(visible);

    vy = min(vy + gravity * dt, maxFall);
    var newY = py + vy * dt;

    if (vy < 0) {
      newY = _resolveCeiling(newY);
    } else if (vy > 0) {
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

  void _resolveShellHits(Floor floor) {
    for (final shell in floor.enemies) {
      if (shell.dead || !shell.shellMoving) continue;
      for (final target in floor.enemies) {
        if (identical(shell, target) || target.dead || target.isShell) continue;
        if (_angDiff(shell.theta, target.theta).abs() > 0.20) continue;
        target.dead = true;
        score += 250;
        renderer.spawnStompPoof(floor, target);
        renderer.spawnFloatText(floor.y - 52, '+250');
      }
    }
  }

  void _resolveFireHits(List<Floor> floors) {
    for (final shot in fireShots) {
      if (shot.dead) continue;
      for (final floor in floors) {
        if ((floor.y - shot.y).abs() > 76) continue;
        for (final enemy in floor.enemies) {
          if (enemy.dead) continue;
          if (_angDiff(shot.theta, enemy.theta).abs() > 0.22) continue;
          enemy.dead = true;
          shot.dead = true;
          score += 200;
          renderer.spawnStompPoof(floor, enemy);
          renderer.spawnFloatText(floor.y - 52, '+200');
          break;
        }
        if (shot.dead) break;
      }
    }
    fireShots.removeWhere((shot) => shot.dead);
  }

  double get _playerHeight => superForm ? 62.0 : 46.0;

  /// Impede que a cabeça atravesse um andar durante a subida.
  ///
  /// Um vão continua atravessável, permitindo que o pulo duplo leve o
  /// personagem de volta ao andar de cima. Em uma parte sólida, ele encosta
  /// na face inferior da plataforma e começa a cair.
  double _resolveCeiling(double newY) {
    final oldHead = py - _playerHeight;
    final newHead = newY - _playerHeight;
    if (newHead >= oldHead) return newY;

    final first = max(
        0,
        ((newHead - Tower.thickness - Tower.firstY) / Tower.floorSpacing)
                .floor() -
            1);
    final last = max(
        first,
        ((oldHead - Tower.thickness - Tower.firstY) / Tower.floorSpacing)
                .ceil() +
            1);
    tower.ensureFloors(last + 2);

    final local = _localTheta();
    for (var i = last; i >= first; i--) {
      final floor = tower.floors[i];
      if (floor.broken) continue;
      final underside = floor.y + Tower.thickness;
      if (underside >= oldHead || underside < newHead) continue;
      if (floor.segAt(local) == SegType.gap) continue;

      if (starT > 0) {
        _breakFloor(floor);
        continue;
      }

      vy = 90;
      shakeT = max(shakeT, 0.08);
      return underside + _playerHeight;
    }
    return newY;
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

    // O primeiro andar intacto encontrado após a estrela vira um pouso
    // garantido: anel completo, sem espinhos e sem inimigos.
    if (_safeLandingAfterStar) {
      _makeFloorNeutral(floor);
      _safeLandingAfterStar = false;
      _bounce(floor);
      renderer.spawnFloatText(floor.y - 48, 'POUSO SEGURO!');
      return true;
    }

    final seg = floor.segAt(local);
    if (seg == SegType.gap) {
      passStreak++;
      if (passStreak == 3) GameAudio.play(GameAudio.fever);
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

    // Cair normalmente sobre qualquer inimigo causa dano. Os inimigos sem
    // espinhos só podem ser derrotados com o mergulho giratório.
    for (final e in floor.enemies) {
      if (e.dead) continue;
      if (_angDiff(e.theta, local).abs() < 0.30) {
        if (spinDive && e.kind != EnemyKind.spiky) {
          _spinDefeat(floor, e);
          return true;
        }
        if (invulnT > 0) {
          _bounce(floor);
          return true;
        }
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
    spinDive = false;
    spinAngle = 0;
    _airJumpUsed = false;
    _lastPlayTapT = -10;
    renderer.spawnDust(floor.y);
    GameAudio.play(GameAudio.jump, volume: 0.6);
  }

  void _makeFloorNeutral(Floor floor) {
    for (var i = 0; i < floor.segs.length; i++) {
      floor.segs[i] = SegType.safe;
    }
    floor.enemies.clear();
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
    GameAudio.play(GameAudio.brick);
    renderer.spawnDebris(floor);
    for (final e in floor.enemies) {
      if (!e.dead) {
        e.dead = true;
        score += 100;
      }
    }
    renderer.spawnFloatText(floor.y - 40, '+300');
  }

  void _spinDefeat(Floor floor, Enemy e) {
    if (e.isKoopa) {
      e.becomeShell(e.facingRight ? 1 : -1);
      score += 300;
      renderer.spawnFloatText(floor.y - 60, 'CASCO!');
    } else if (e.isShell) {
      e.launchShell(e.facingRight ? 1 : -1);
      score += 100;
      renderer.spawnFloatText(floor.y - 60, 'CHUTE!');
    } else {
      e.dead = true;
      score += 200;
      renderer.spawnFloatText(floor.y - 60, '+200');
    }
    GameAudio.play(GameAudio.stomp);
    renderer.spawnStompPoof(floor, e);
    _bounce(floor, boost: 1.12);
  }

  /// Aplica dano. Retorna true se o jogador sobreviveu.
  bool _damage(Floor floor) {
    if (firePower) {
      firePower = false;
      superForm = true;
      invulnT = 2.5;
      GameAudio.play(GameAudio.hurt);
      _bounce(floor);
      return true;
    }
    if (superForm) {
      superForm = false;
      invulnT = 2.5;
      GameAudio.play(GameAudio.hurt);
      _bounce(floor);
      return true;
    }
    _die();
    return false;
  }

  void _die() {
    state = GState.dying;
    stateT = 0;
    spinDive = false;
    vy = -750;
    GameAudio.play(GameAudio.death);
  }

  void _finishDeath() {
    if (score > best) {
      best = score;
      newBest = true;
      _prefs?.setInt('best', best);
    }
    state = GState.gameOver;
    stateT = 0;
    GameAudio.play(GameAudio.gameover);
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
            GameAudio.play(GameAudio.coin);
            renderer.spawnSparkle(itemY);
            renderer.spawnFloatText(itemY - 20, '+100');
          case ItemKind.mushroom:
            if (superForm || firePower) {
              score += 500;
              renderer.spawnFloatText(itemY - 20, '+500');
            } else {
              superForm = true;
              renderer.spawnFloatText(itemY - 20, 'SUPER!');
            }
            GameAudio.play(GameAudio.powerup);
            renderer.spawnSparkle(itemY);
          case ItemKind.fireFlower:
            superForm = true;
            firePower = true;
            GameAudio.play(GameAudio.powerup);
            renderer.spawnFloatText(itemY - 20, 'FLOR DE FOGO!');
            renderer.spawnSparkle(itemY);
          case ItemKind.star:
            starT = 8;
            GameAudio.play(GameAudio.star);
            passStreak = 0;
            _safeLandingAfterStar = false;
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

  List<FireShot> visibleFireShots() => fireShots
      .where((shot) => shot.y - camY > -100 && shot.y - camY < designH + 100)
      .toList();

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
