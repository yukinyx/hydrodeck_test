import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
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

class WeatherForecastHour {
  final DateTime time;
  final double? temperature;
  final int? weatherCode;
  final int? precipitationProbability;

  const WeatherForecastHour({
    required this.time,
    required this.temperature,
    required this.weatherCode,
    required this.precipitationProbability,
  });
}

class WeatherConditions {
  final WeatherLocation location;
  final double? temperature;
  final double? feelsLike;
  final int? humidity;
  final double? precipitation;
  final double? windSpeed;
  final int? weatherCode;
  final List<WeatherForecastHour> hourly;
  final List<WeatherForecastDay> forecast;

  const WeatherConditions({
    required this.location,
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.precipitation,
    required this.windSpeed,
    required this.weatherCode,
    required this.hourly,
    required this.forecast,
  });
}

class WeatherService {
  static WeatherConditions? lastSuccessfulConditions;

  static Future<WeatherLocation> currentLocation() async {
    try {
      final locationServiceEnabled =
          await Geolocator.isLocationServiceEnabled();

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        throw const WeatherException(
          'Location permission is permanently denied. Allow location access in app settings, then retry.',
          canOpenSettings: true,
        );
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        throw const WeatherException(
          'Location permission was denied. Allow location access, then retry.',
        );
      }

      Position? position;
      Object? locationError;
      if (locationServiceEnabled) {
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.low,
              timeLimit: Duration(seconds: 15),
            ),
          );
        } catch (error) {
          locationError = error;
        }
      } else {
        locationError = const WeatherException(
          'Location services are turned off. Turn them on, then retry.',
        );
      }
      if (position == null) {
        try {
          position = await Geolocator.getLastKnownPosition();
        } catch (error) {
          locationError ??= error;
        }
      }
      if (position == null) {
        if (locationError != null) throw locationError;
        throw const WeatherException(
          'Could not get your current location. Check location permissions and services, then retry.',
        );
      }
      return WeatherLocation(
        name: 'Current location',
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } on WeatherException {
      rethrow;
    } on TimeoutException {
      throw const WeatherException(
        'Getting your current location timed out. Check location services, then retry.',
      );
    } on MissingPluginException {
      throw const WeatherException('Location is not supported on this device.');
    } on UnsupportedError {
      throw const WeatherException('Location is not supported on this device.');
    } on PlatformException {
      throw const WeatherException(
        'Could not access device location. Check location permissions and services, then retry.',
      );
    } on Exception {
      throw const WeatherException(
        'Could not get your current location. Check location permissions and services, then retry.',
      );
    }
  }

  static Future<WeatherConditions> fetch(WeatherLocation location) async {
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': location.latitude.toString(),
      'longitude': location.longitude.toString(),
      'current':
          'temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m',
      'hourly': 'temperature_2m,precipitation_probability,weather_code',
      'forecast_hours': '24',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'forecast_days': '5',
      'timezone': 'auto',
    });
    http.Response? response;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        response = await http.get(uri).timeout(const Duration(seconds: 15));
        break;
      } catch (error) {
        final retryable =
            error is TimeoutException ||
            error is http.ClientException ||
            error.runtimeType.toString() == 'SocketException';
        if (!retryable) rethrow;
        if (attempt == 0) continue;
        if (error is TimeoutException) {
          throw const WeatherException(
            'The weather request timed out. Check your connection, then retry.',
          );
        }
        throw const WeatherException(
          'No internet connection. If you\'re connected to the Hydrodeck hotspot, switch to home Wi-Fi or mobile data.',
        );
      }
    }
    if (response == null) {
      throw const WeatherException(
        'Could not connect to the weather service. Please retry.',
      );
    }
    if (response.statusCode != 200) {
      throw WeatherException(
        'Weather service returned HTTP ${response.statusCode}.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const WeatherException('Weather returned invalid data.');
    }
    final current = decoded['current'];
    final hourly = decoded['hourly'];
    final daily = decoded['daily'];
    if (current is! Map<String, dynamic> ||
        hourly is! Map<String, dynamic> ||
        daily is! Map<String, dynamic>) {
      throw const WeatherException('Weather returned incomplete data.');
    }
    final hourlyTimes = hourly['time'];
    final hourlyTemperatures = hourly['temperature_2m'];
    final hourlyCodes = hourly['weather_code'];
    final hourlyPrecipitation = hourly['precipitation_probability'];
    final hourlyForecast = <WeatherForecastHour>[];
    if (hourlyTimes is List &&
        hourlyTemperatures is List &&
        hourlyCodes is List) {
      final now = DateTime.now();
      for (var index = 0; index < hourlyTimes.length; index++) {
        final time = DateTime.tryParse(hourlyTimes[index].toString());
        if (time == null || time.isBefore(now)) continue;
        hourlyForecast.add(
          WeatherForecastHour(
            time: time,
            temperature: _numberAt(hourlyTemperatures, index),
            weatherCode: _integerAt(hourlyCodes, index),
            precipitationProbability: _integerAt(hourlyPrecipitation, index),
          ),
        );
        if (hourlyForecast.length == 12) break;
      }
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
    final conditions = WeatherConditions(
      location: location,
      temperature: _number(current['temperature_2m']),
      feelsLike: _number(current['apparent_temperature']),
      humidity: _integer(current['relative_humidity_2m']),
      precipitation: _number(current['precipitation']),
      windSpeed: _number(current['wind_speed_10m']),
      weatherCode: _integer(current['weather_code']),
      hourly: hourlyForecast,
      forecast: forecast,
    );
    lastSuccessfulConditions = conditions;
    return conditions;
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
  final bool canOpenSettings;

  const WeatherException(this.message, {this.canOpenSettings = false});

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
