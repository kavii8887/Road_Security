// lib/models/report_model.dart
class ReportModel {
  final String? id;
  final String createdAt;
  final double latitude;
  final double longitude;
  final double confidence;
  final String mapsLink;
  final String imageUrl;
  final String status;

  ReportModel({
    this.id,
    required this.createdAt,
    required this.latitude,
    required this.longitude,
    required this.confidence,
    required this.mapsLink,
    required this.imageUrl,
    this.status = 'pending',
  });

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'created_at': createdAt,
      'latitude': latitude,
      'longitude': longitude,
      'confidence': confidence,
      'maps_link': mapsLink,
      'image_url': imageUrl,
      'status': status,
    };
  }

  factory ReportModel.fromJson(Map<String, dynamic> json) {
    return ReportModel(
      id: json['id'],
      createdAt: json['created_at'],
      latitude: json['latitude'].toDouble(),
      longitude: json['longitude'].toDouble(),
      confidence: json['confidence'].toDouble(),
      mapsLink: json['maps_link'],
      imageUrl: json['image_url'],
      status: json['status'] ?? 'pending',
    );
  }
}
