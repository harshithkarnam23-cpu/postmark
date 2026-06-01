import 'package:flutter/material.dart';

class LegalTermsPage extends StatelessWidget {
  const LegalTermsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF0A84FF), size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Legal Terms',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            color: const Color(0xFF2C2C2E),
            height: 1,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Terms of Service & Privacy Policy',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Last updated: May 2026',
                style: TextStyle(
                  color: Color(0xFF8E8E93),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              _buildSection(
                title: '1. Acceptance of Terms',
                content:
                    'Welcome to PostMark. By accessing or using our application, you agree to be bound by these Terms of Service. If you do not agree, please do not use the application.',
              ),
              _buildSection(
                title: '2. User Accounts',
                content:
                    'To use our services, you must register for an account using either Google Sign-In or your Email/Password. You agree to provide accurate and complete registration information. You are solely responsible for maintaining the confidentiality of your account credentials.',
              ),
              _buildSection(
                title: '3. Data & Privacy',
                content:
                    'Your privacy is our priority. We collect minimal personal details (username, email, date of birth, and optional profile picture) to provide a tailored messaging experience. We do not sell your personal data to third parties. All communication data is handled securely via Firebase.',
              ),
              _buildSection(
                title: '4. Content Guidelines',
                content:
                    'You are responsible for all content (chats, moments, media) you post. PostMark reserves the right to terminate accounts that violate community guidelines, distribute harmful content, or engage in abusive behavior.',
              ),
              _buildSection(
                title: '5. Limitation of Liability',
                content:
                    'PostMark is provided "as is" without warranties of any kind. We are not liable for any indirect, incidental, or consequential damages arising out of your use of our application.',
              ),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  '© 2026 PostMark. All Rights Reserved.',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection({required String title, required String content}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2C2C2E), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF0A84FF),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: const TextStyle(
              color: Color(0xFFE5E5EA),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
