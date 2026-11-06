import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

final Uri hydrodeckSupportEndpoint = Uri(
  scheme: 'https',
  host: 'formspree.io',
  path: '/f/xjyyzzql',
);

class SupportRequest {
  final String name;
  final String replyEmail;
  final String subject;
  final String message;

  const SupportRequest({
    required this.name,
    required this.replyEmail,
    required this.subject,
    required this.message,
  });
}

class SupportSubmissionException implements Exception {
  final int statusCode;

  const SupportSubmissionException(this.statusCode);

  @override
  String toString() => 'Formspree returned HTTP $statusCode.';
}

Future<void> submitSupportRequest({
  required http.Client client,
  required SupportRequest request,
}) async {
  final response = await client
      .post(
        hydrodeckSupportEndpoint,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': request.name,
          'email': request.replyEmail,
          'subject': request.subject,
          'message': request.message,
        }),
      )
      .timeout(const Duration(seconds: 20));

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw SupportSubmissionException(response.statusCode);
  }
}

class SupportRequestScreen extends StatefulWidget {
  final http.Client? client;

  const SupportRequestScreen({super.key, this.client});

  @override
  State<SupportRequestScreen> createState() => _SupportRequestScreenState();
}

class _SupportRequestScreenState extends State<SupportRequestScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _subject = TextEditingController();
  final _message = TextEditingController();

  late final http.Client _client;
  late final bool _ownsClient;
  bool _submitting = false;
  String? _statusMessage;
  bool _submissionSucceeded = false;

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.client == null;
    _client = widget.client ?? http.Client();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _subject.dispose();
    _message.dispose();
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _submitting = true;
      _statusMessage = null;
    });

    try {
      await submitSupportRequest(
        client: _client,
        request: SupportRequest(
          name: _name.text.trim(),
          replyEmail: _email.text.trim(),
          subject: _subject.text.trim(),
          message: _message.text.trim(),
        ),
      );
      if (!mounted) return;
      setState(() {
        _submissionSucceeded = true;
        _statusMessage = 'Your support request was submitted successfully.';
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        _submissionSucceeded = false;
        _statusMessage =
            'We could not submit your request. Please check your connection and try again.';
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _required(String? value, String label) {
    if (value == null || value.trim().isEmpty) return 'Enter your $label.';
    return null;
  }

  String? _validateEmail(String? value) {
    final requiredError = _required(value, 'reply email');
    if (requiredError != null) return requiredError;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value!.trim())) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Customer Support'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Send a request to the HydroDeck Project Team.',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                'Do not include passwords, Wi-Fi credentials, or other secrets.',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: const ValueKey('support-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => _required(value, 'name'),
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('support-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Reply email',
                  border: OutlineInputBorder(),
                ),
                validator: _validateEmail,
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('support-subject'),
                controller: _subject,
                decoration: const InputDecoration(
                  labelText: 'Subject',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => _required(value, 'subject'),
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('support-message'),
                controller: _message,
                minLines: 5,
                maxLines: 8,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                validator: (value) => _required(value, 'message'),
              ),
              const SizedBox(height: 18),
              if (_statusMessage != null) ...[
                Text(
                  _statusMessage!,
                  key: const ValueKey('support-status'),
                  style: TextStyle(
                    color: _submissionSucceeded
                        ? const Color(0xFF168A43)
                        : Colors.red.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              ElevatedButton(
                key: const ValueKey('support-submit'),
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2DC867),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Send request'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
