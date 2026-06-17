// lib/services/location_service.dart
import 'package:geolocator/geolocator.dart';

class LocationService {
  Future<Position?> getCurrentLocation() async {
    try {
      bool serviceEnabled;
      LocationPermission permission;

      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('Location services are disabled.');
        return await Geolocator.getLastKnownPosition();
      }

      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('Location permissions are denied');
          return null;
        }
      }
      
      if (permission == LocationPermission.deniedForever) {
        print('Location permissions are permanently denied');
        return null;
      } 

      // Request fresh location with a longer 15-second timeout for hardware
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 15),
      );
    } catch (e) {
      print('Failed to get current position ($e), falling back to last known...');
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (e2) {
        return null; 
      }
    }
  }

  String getGoogleMapsLink(double lat, double lng) {
    return 'https://www.google.com/maps?q=$lat,$lng';
  }
}

