// lib/main.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:camera/camera.dart';
import 'screens/login_screen.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    cameras = await availableCameras();
  } catch (e) {
    print('Camera Error: $e');
  }

  await Supabase.initialize(
    url: 'https://kmnibwkybzcymefsqdjk.supabase.co', // REPLACE WITH YOUR URL
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imttbmlid2t5YnpjeW1lZnNxZGprIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzNzczMzgsImV4cCI6MjA4OTk1MzMzOH0.9Ohwfzh0V4rs16plIHSJSui9yJTFpL-zhQZWORBxqxk', // REPLACE WITH YOUR ANON KEY
  );

  runApp(const RoadSecurityApp());
}

class RoadSecurityApp extends StatelessWidget {
  const RoadSecurityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Road Security',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}
