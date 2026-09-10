import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ResourceCard extends StatelessWidget {
  final dynamic data;
  const ResourceCard({super.key, required this.data});

  void _openLink(String url) async {
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: ListTile(
        leading: Icon(Icons.picture_as_pdf, color: Theme.of(context).primaryColor),
        title: Text(data['title'] ?? 'No Title'),
        subtitle: Text('${data['course']} • ${data['examType']}'),
        trailing: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () => _openLink(data['fileUrl']),
        ),
      ),
    );
  }
}