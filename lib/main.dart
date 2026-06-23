import 'package:flutter/material.dart';

import 'src/youface_prototype.dart';

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
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'YouFace Camera Test',
      debugShowCheckedModeBanner: false,
      home: const YouFacePrototypeScreen(),
    );
  }
}
