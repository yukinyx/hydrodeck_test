import 'package:firebase_auth/firebase_auth.dart';

final RegExp loginEmailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? validateLoginFields({
  required String email,
  required String password,
}) {
  final trimmedEmail = email.trim();
  if (trimmedEmail.isEmpty && password.isEmpty) {
    return 'Please enter your email address and password.';
  }
  if (trimmedEmail.isEmpty) {
    return 'Please enter your email address.';
  }
  if (password.isEmpty) {
    return 'Please enter your password.';
  }
  if (!loginEmailPattern.hasMatch(trimmedEmail)) {
    return 'Please enter a valid email address.';
  }
  return null;
}

String friendlyLoginAuthMessage(String code) {
  switch (code) {
    case 'invalid-email':
      return 'Please enter a valid email address.';
    case 'user-disabled':
      return 'This account has been disabled. Please contact support.';
    case 'too-many-requests':
      return 'Too many unsuccessful attempts. Please wait and try again later.';
    case 'network-request-failed':
      return 'Unable to connect. Please check your internet connection and try again.';
    case 'user-not-found':
    case 'wrong-password':
    case 'invalid-credential':
    case 'INVALID_LOGIN_CREDENTIALS':
    case 'invalid-login-credentials':
    case 'invalid-credentials':
      return 'Incorrect email or password. Please check your details and try again.';
    default:
      return 'Login failed. Please try again.';
  }
}

String friendlyLoginException(Object error) {
  if (error is FirebaseAuthException) {
    return friendlyLoginAuthMessage(error.code);
  }
  final text = error.toString().toLowerCase();
  if (text.contains('socket') ||
      text.contains('network') ||
      text.contains('failed host lookup') ||
      text.contains('connection')) {
    return 'Unable to connect. Please check your internet connection and try again.';
  }
  return 'Login failed. Please try again.';
}
