import 'package:flutter_test/flutter_test.dart';
import 'package:super_helix_world/src/game.dart';
import 'package:super_helix_world/src/model.dart';

void main() {
  test('arrastar para baixo inicia o mergulho giratório', () {
    final game = SuperHelixGame()
      ..state = GState.playing
      ..time = 1
      ..lastBounceT = 0
      ..vy = -200;

    game.onDragStart();
    game.onDragUpdate(0, 60);

    expect(game.spinDive, isTrue);
    expect(game.vy, SuperHelixGame.spinDiveV);
  });

  test('arrastar para cima dispara duas bolas com a flor', () {
    final game = SuperHelixGame()
      ..state = GState.playing
      ..firePower = true
      ..py = 200;

    game.onDragStart();
    game.onDragUpdate(0, -60);

    expect(game.fireShots, hasLength(2));
    expect(game.fireShots[0].angularV, lessThan(0));
    expect(game.fireShots[1].angularV, greaterThan(0));
  });

  test('Koopa vira casco lançado ao receber o ataque', () {
    final koopa = Enemy(
      kind: EnemyKind.koopaRed,
      center: 1,
      halfRange: 0.5,
      speed: 1,
      phase: 0,
    );
    final before = koopa.theta;

    koopa.becomeShell(1);
    koopa.update(0.1);

    expect(koopa.kind, EnemyKind.shellRed);
    expect(koopa.shellMoving, isTrue);
    expect(koopa.theta, isNot(before));
  });
}
