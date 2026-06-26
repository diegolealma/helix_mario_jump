import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/game.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
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
          onPanStart: (_) => game.onDragStart(),
          onPanUpdate: (d) => game.onDragUpdate(d.delta.dx, d.delta.dy),
          onPanEnd: (_) => game.onDragEnd(),
          onTapUp: (_) => game.onTapScreen(),
          child: GameWidget(game: game),
        ),
      ),
    );
  }
}
