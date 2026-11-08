import 'dart:convert';

import 'package:http/http.dart' as http;

class WeatherLocation {
  final String name;
  final double latitude;
  final double longitude;

  const WeatherLocation({
    required this.name,
    required this.latitude,
    required this.longitude,
  });
}

class WeatherForecastDay {
  final DateTime date;
  final double? minimumTemperature;
  final double? maximumTemperature;
  final int? weatherCode;
  final int? precipitationProbability;

  const WeatherForecastDay({
    required this.date,
    required this.minimumTemperature,
    required this.maximumTemperature,
    required this.weatherCode,
    required this.precipitationProbability,
  });
}

class WeatherConditions {
  final WeatherLocation location;
  final double? temperature;
  final double? feelsLike;
  final int? humidity;
  final double? windSpeed;
  final int? weatherCode;
  final List<WeatherForecastDay> forecast;

  const WeatherConditions({
    required this.location,
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.windSpeed,
    required this.weatherCode,
    required this.forecast,
  });
}

class WeatherService {
  static Future<List<WeatherLocation>> searchLocations(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return const [];
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': trimmed,
      'count': '5',
      'language': 'en',
      'format': 'json',
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw const WeatherException('Location search is unavailable.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const WeatherException('Location search returned invalid data.');
    }
    final results = decoded['results'];
    if (results is! List) return const [];
    return results.whereType<Map<String, dynamic>>().map((result) {
      final name = result['name'];
      final latitude = result['latitude'];
      final longitude = result['longitude'];
      if (name is! String || latitude is! num || longitude is! num) {
        throw const WeatherException('Location search returned invalid data.');
      }
      final region = result['admin1'] as String?;
      final country = result['country'] as String?;
      final label = [
        name,
        region,
        country,
      ].whereType<String>().where((part) => part.isNotEmpty).toSet().join(', ');
      return WeatherLocation(
        name: label,
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
      );
    }).toList();
  }

  static Future<WeatherConditions> fetch(WeatherLocation location) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': location.latitude.toString(),
      'longitude': location.longitude.toString(),
      'current':
          'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'forecast_days': '5',
      'timezone': 'auto',
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw const WeatherException('Weather is temporarily unavailable.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const WeatherException('Weather returned invalid data.');
    }
    final current = decoded['current'];
    final daily = decoded['daily'];
    if (current is! Map<String, dynamic> || daily is! Map<String, dynamic>) {
      throw const WeatherException('Weather returned incomplete data.');
    }
    final times = daily['time'];
    final min = daily['temperature_2m_min'];
    final max = daily['temperature_2m_max'];
    final codes = daily['weather_code'];
    final precipitation = daily['precipitation_probability_max'];
    final forecast = <WeatherForecastDay>[];
    if (times is List && min is List && max is List && codes is List) {
      for (var index = 0; index < times.length; index++) {
        final date = DateTime.tryParse(times[index].toString());
        if (date == null) continue;
        forecast.add(
          WeatherForecastDay(
            date: date,
            minimumTemperature: _numberAt(min, index),
            maximumTemperature: _numberAt(max, index),
            weatherCode: _integerAt(codes, index),
            precipitationProbability: _integerAt(precipitation, index),
          ),
        );
      }
    }
    return WeatherConditions(
      location: location,
      temperature: _number(current['temperature_2m']),
      feelsLike: _number(current['apparent_temperature']),
      humidity: _integer(current['relative_humidity_2m']),
      windSpeed: _number(current['wind_speed_10m']),
      weatherCode: _integer(current['weather_code']),
      forecast: forecast,
    );
  }

  static double? _number(Object? value) =>
      value is num && value.isFinite ? value.toDouble() : null;

  static int? _integer(Object? value) =>
      value is num && value.isFinite ? value.round() : null;

  static double? _numberAt(Object? values, int index) =>
      values is List && index < values.length ? _number(values[index]) : null;

  static int? _integerAt(Object? values, int index) =>
      values is List && index < values.length ? _integer(values[index]) : null;
}

class WeatherException implements Exception {
  final String message;

  const WeatherException(this.message);

  @override
  String toString() => message;
}

String weatherDescription(int? code) => switch (code) {
  0 => 'Clear sky',
  1 || 2 => 'Mostly clear',
  3 => 'Overcast',
  45 || 48 => 'Fog',
  51 || 53 || 55 || 56 || 57 => 'Drizzle',
  61 || 63 || 65 || 66 || 67 => 'Rain',
  71 || 73 || 75 || 77 => 'Snow',
  80 || 81 || 82 => 'Rain showers',
  85 || 86 => 'Snow showers',
  95 || 96 || 99 => 'Thunderstorm',
  _ => 'Conditions unavailable',
};
