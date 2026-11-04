import 'package:firebase_auth/firebase_auth.dart';

final RegExp loginEmailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final RegExp signupPhonePattern = RegExp(r'^09\d{9}$');

String? validateEmailField(String email) {
  if (email.trim().isEmpty) return 'Please enter your email address.';
  if (!loginEmailPattern.hasMatch(email.trim())) {
    return 'Please enter a valid email address.';
  }
  return null;
}

String? validatePasswordField(String password) => password.isEmpty
    ? 'Please enter your password.'
    : null;

String? validateSignupPhoneField(String phone) {
  if (phone.trim().isEmpty) return 'Please enter your phone number.';
  if (!signupPhonePattern.hasMatch(phone.trim())) {
    return 'Phone number must be 11 digits and start with 09.';
  }
  return null;
}

String? validateSignupPasswordField(String password) {
  if (password.isEmpty) return 'Please enter a password.';
  if (password.length < 6) return 'Password must be at least 6 characters.';
  return null;
}

String? validateConfirmPasswordField(String password, String confirmation) {
  if (confirmation.isEmpty) return 'Please confirm your password.';
  if (password != confirmation) return 'Passwords do not match.';
  return null;
}

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
  return validateEmailField(trimmedEmail);
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
