import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'src/game.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SuperMaiorWorldApp());
}

class SuperMaiorWorldApp extends StatefulWidget {
  const SuperMaiorWorldApp({super.key});

  @override
  State<SuperMaiorWorldApp> createState() => _SuperMaiorWorldAppState();
}

class _SuperMaiorWorldAppState extends State<SuperMaiorWorldApp> {
  final game = SuperHelixGame();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Super Maior World',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => game.onDragDx(d.delta.dx),
          onTapUp: (_) => game.onTapScreen(),
          child: GameWidget(game: game),
        ),
      ),
    );
  }
}
