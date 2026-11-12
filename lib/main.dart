import 'package:flutter/material.dart';
import 'screens/camera_screen.dart';
import 'screens/photos_screen.dart';
import 'services/inference_service.dart';
import 'services/photo_saver.dart';

void main() {
  // Initialize the ONNX runtime environment once, before the app starts.
  InferenceService.init();
  // Background one-time repair: make previously saved dataset photos
  // group-readable so they can be pulled over adb (see PhotoSaver).
  PhotoSaver.makeShareable();
  runApp(const AiLuxApp());
}

class AiLuxApp extends StatelessWidget {
  const AiLuxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Lux',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D9E75),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D9E75),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const PlaceholderScreen(),
    );
  }
}

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.camera_alt,
                size: 64, color: const Color(0xFF1D9E75)),
            const SizedBox(height: 16),
            const Text(
              'AI Lux',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            const Text(
              'Workplace illuminance estimation',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CameraScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.camera),
              label: const Text('Open camera'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1D9E75),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PhotosScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Saved photos'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1D9E75),
                side: const BorderSide(color: Color(0xFF1D9E75)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}