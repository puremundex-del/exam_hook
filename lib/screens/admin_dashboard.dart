import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _newSubjectController = TextEditingController();
  final _searchController = TextEditingController();

  String _course = 'Maths';
  String _examType = 'Notes';
  bool _isUploading = false;
  String _searchQuery = '';

  final supabase = Supabase.instance.client;
  final firestore = FirebaseFirestore.instance;
  final uuid = const Uuid();

  Uint8List? _fileBytes;
  String? _fileName;

  List<String> subjects = ['Maths', 'Physics', 'Chemistry', 'Biology'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      DocumentReference settingsRef =
          firestore.collection('settings').doc('app');
      DocumentSnapshot doc = await settingsRef.get();
      if (doc.exists) {
        var data = doc.data() as Map<String, dynamic>?;
        if (data != null && data['subjects'] != null) {
          setState(() {
            subjects = List<String>.from(data['subjects']);
          });
        }
      } else {
        await settingsRef.set(
          {'subjects': subjects},
          SetOptions(merge: true),
        );
      }
    } catch (e) {
      debugPrint("Load settings error: $e");
    }
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'docx'],
      withData: true,
    );

    if (result != null) {
      setState(() {
        _fileBytes = result.files.first.bytes;
        _fileName = result.files.first.name;
      });
    }
  }

  Future<void> _uploadFile() async {
    if (!_formKey.currentState!.validate() ||
        _fileBytes == null ||
        _fileName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please pick a file first'),
        ),
      );
      return;
    }

    String uniqueFileName = '${uuid.v4()}_$_fileName';

    setState(() => _isUploading = true);

    try {
      // 1. Upload to Supabase
      await supabase.storage
          .from('examhook-files')
          .uploadBinary(uniqueFileName, _fileBytes!);

      String fileUrl = supabase.storage
          .from('examhook-files')
          .getPublicUrl(uniqueFileName);

      // 2. Save to Firestore
      await firestore.collection('resources').add({
        'title': _titleController.text,
        'course': _course,
        'examType': _examType,
        'fileUrl': fileUrl,
        'fileName': uniqueFileName,
        'fileSize': _fileBytes!.length,
        'likes': 0,
        'rating': 0.0,
        'ratingCount': 0,
        'downloads': 0,
        'uploadedAt': FieldValue.serverTimestamp()
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Resource Uploaded!'),
          backgroundColor: Colors.green,
        ),
      );

      _titleController.clear();

      setState(() {
        _fileBytes = null;
        _fileName = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }

    setState(() => _isUploading = false);
  }

  Future<void> _deleteResource(String docId, String fileName) async {
    bool confirm = await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete Resource'),
            content: const Text(
              'Delete this file from storage and database?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (confirm) {
      try {
        await supabase.storage
            .from('examhook-files')
            .remove([fileName]);
      } catch (e) {
        debugPrint("Supabase delete error: $e");
      }

      await firestore.collection('resources').doc(docId).delete();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Deleted'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _approvePending(String docId, Map data) async {
    try {
      // Move file from pending_uploads/ to root
      String oldPath = data['fileName'];
      String newFileName =
          oldPath.replaceFirst('pending_uploads/', '');

      // Copy file in supabase
      final bytes = await supabase.storage
          .from('examhook-files')
          .download(oldPath);

      await supabase.storage
          .from('examhook-files')
          .uploadBinary(newFileName, bytes);

      String newUrl = supabase.storage
          .from('examhook-files')
          .getPublicUrl(newFileName);

      // Delete old pending file
      await supabase.storage
          .from('examhook-files')
          .remove([oldPath]);

      // Add to resources collection
      await firestore.collection('resources').add({
        ...data,
        'fileName': newFileName,
        'fileUrl': newUrl,
        'status': 'approved',
        'uploadedAt': FieldValue.serverTimestamp(),
      });

      await firestore
          .collection('resources_pending')
          .doc(docId)
          .delete();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Approved!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Approve failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _rejectPending(
      String docId, String fileName) async {
    try {
      await supabase.storage
          .from('examhook-files')
          .remove([fileName]);
    } catch (e) {
      debugPrint("Supabase delete error: $e");
    }

    await firestore
        .collection('resources_pending')
        .doc(docId)
        .delete();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Rejected & Deleted'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  // NEW: View pending uploaded file before approving/rejecting.
  Future<void> _viewPendingFile(String fileUrl, String fileName) async {
    if (fileUrl.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File preview is not available.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final String lowerName = fileName.toLowerCase();
    final String lowerUrl = fileUrl.toLowerCase();

    final bool isImage = lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.png') ||
        lowerUrl.contains('.jpg') ||
        lowerUrl.contains('.jpeg') ||
        lowerUrl.contains('.png');

    if (isImage) {
      showDialog(
        context: context,
        builder: (context) {
          return Dialog(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  automaticallyImplyLeading: false,
                  title: Text(
                    fileName,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                Flexible(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.network(
                      fileUrl,
                      fit: BoxFit.contain,
                      loadingBuilder:
                          (context, child, loadingProgress) {
                        if (loadingProgress == null) {
                          return child;
                        }

                        return const Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(
                            child: CircularProgressIndicator(),
                          ),
                        );
                      },
                      errorBuilder:
                          (context, error, stackTrace) {
                        return const Padding(
                          padding: EdgeInsets.all(30),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.broken_image,
                                size: 60,
                                color: Colors.grey,
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Unable to preview this image.',
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    } else {
      // PDFs and DOCX files are opened using the device/browser.
      try {
        final Uri uri = Uri.parse(fileUrl);

        final bool launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );

        if (!launched && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to open this file.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unable to open file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _addSubject() async {
    if (_newSubjectController.text.isEmpty) return;

    String newSub = _newSubjectController.text.trim();

    if (!subjects.contains(newSub)) {
      setState(() => subjects.add(newSub));

      await firestore
          .collection('settings')
          .doc('app')
          .set(
            {'subjects': subjects},
            SetOptions(merge: true),
          );

      _newSubjectController.clear();
    }
  }

  Future<void> _deleteSubject(String subject) async {
    setState(() => subjects.remove(subject));

    await firestore
        .collection('settings')
        .doc('app')
        .set(
          {'subjects': subjects},
          SetOptions(merge: true),
        );
  }

  Future<void> _deleteRequest(String docId) async {
    await firestore
        .collection('requests')
        .doc(docId)
        .delete();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Request Deleted'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _deleteComment(
      String resourceId, String commentId) async {
    await firestore
        .collection('resources')
        .doc(resourceId)
        .collection('comments')
        .doc(commentId)
        .delete();
  }

  @override
  Widget build(BuildContext context) {
    const Color primaryGreen = Color(0xFF00C896);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Admin Dashboard',
          style: GoogleFonts.poppins(
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: primaryGreen,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(
              icon: Icon(Icons.upload),
              text: 'Upload',
            ),
            Tab(
              icon: Icon(Icons.list),
              text: 'Manage',
            ),
            Tab(
              icon: Icon(Icons.pending_actions),
              text: 'Pending',
            ),
            Tab(
              icon: Icon(Icons.settings),
              text: 'Settings',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // TAB 1: UPLOAD
          Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: ListView(
                children: [
                  TextFormField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Resource Title',
                      border: OutlineInputBorder(),
                    ),
                    validator: (val) =>
                        val!.isEmpty ? 'Enter title' : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: _course,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      border: OutlineInputBorder(),
                    ),
                    items: subjects
                        .map(
                          (e) => DropdownMenuItem(
                            value: e,
                            child: Text(e),
                          ),
                        )
                        .toList(),
                    onChanged: (val) =>
                        setState(() => _course = val!),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: _examType,
                    decoration: const InputDecoration(
                      labelText: 'Exam Type',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      'ExamPrac',
                      'Notes',
                      'Quiz',
                      'Assignment'
                    ]
                        .map(
                          (e) => DropdownMenuItem(
                            value: e,
                            child: Text(e),
                          ),
                        )
                        .toList(),
                    onChanged: (val) =>
                        setState(() => _examType = val!),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.attach_file),
                    label: Text(
                      _fileName == null
                          ? 'Pick File'
                          : _fileName!,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _isUploading
                      ? const Center(
                          child: CircularProgressIndicator(),
                        )
                      : ElevatedButton.icon(
                          icon: const Icon(Icons.cloud_upload),
                          label: const Text(
                            'Upload to Supabase',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryGreen,
                            minimumSize:
                                const Size(double.infinity, 50),
                          ),
                          onPressed: _uploadFile,
                        ),
                ],
              ),
            ),
          ),

          // TAB 2: MANAGE RESOURCES
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText:
                        'Search resources by title, subject...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (val) => setState(
                    () => _searchQuery = val.toLowerCase(),
                  ),
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: firestore
                      .collection('resources')
                      .orderBy(
                        'uploadedAt',
                        descending: true,
                      )
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState ==
                        ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Error: ${snapshot.error}',
                        ),
                      );
                    }

                    if (!snapshot.hasData ||
                        snapshot.data!.docs.isEmpty) {
                      return Center(
                        child: Text(
                          'No resources yet',
                          style: GoogleFonts.poppins(),
                        ),
                      );
                    }

                    var docs = snapshot.data!.docs;

                    if (_searchQuery.isNotEmpty) {
                      docs = docs.where((d) {
                        var data =
                            d.data() as Map<String, dynamic>;

                        return data['title']
                                .toString()
                                .toLowerCase()
                                .contains(_searchQuery) ||
                            data['course']
                                .toString()
                                .toLowerCase()
                                .contains(_searchQuery) ||
                            data['examType']
                                .toString()
                                .toLowerCase()
                                .contains(_searchQuery);
                      }).toList();
                    }

                    return ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        var doc = docs[index];
                        var data =
                            doc.data() as Map<String, dynamic>;

                        return ExpansionTile(
                          leading: Icon(
                            _getFileIcon(
                              data['fileUrl'] ?? '',
                            ),
                            color: primaryGreen,
                          ),
                          title: Text(
                            data['title'] ?? '',
                            style: GoogleFonts.poppins(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${data['course']} • ${data['examType']}\n'
                            'Likes: ${data['likes']} • '
                            'Rating: ${(data['rating'] ?? 0.0).toDouble().toStringAsFixed(1)} • '
                            'Downloads: ${data['downloads']}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete,
                              color: Colors.red,
                            ),
                            onPressed: () => _deleteResource(
                              doc.id,
                              data['fileName'],
                            ),
                          ),
                          children: [
                            StreamBuilder<QuerySnapshot>(
                              stream: firestore
                                  .collection('resources')
                                  .doc(doc.id)
                                  .collection('comments')
                                  .orderBy(
                                    'timestamp',
                                    descending: true,
                                  )
                                  .snapshots(),
                              builder: (context, snap) {
                                if (!snap.hasData ||
                                    snap.data!.docs.isEmpty) {
                                  return const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Text('No comments'),
                                  );
                                }

                                return Column(
                                  children: snap.data!.docs
                                      .map((c) {
                                    var cd =
                                        c.data() as Map;

                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        cd['text'] ?? '',
                                        style:
                                            GoogleFonts.poppins(
                                          fontSize: 13,
                                        ),
                                      ),
                                      subtitle: Text(
                                        cd['user'] ??
                                            'Anonymous',
                                        style:
                                            GoogleFonts.poppins(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 18,
                                        ),
                                        onPressed: () =>
                                            _deleteComment(
                                          doc.id,
                                          c.id,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                );
                              },
                            )
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),

          // TAB 3: PENDING APPROVALS
          StreamBuilder<QuerySnapshot>(
            stream: firestore
                .collection('resources_pending')
                .orderBy(
                  'uploadedAt',
                  descending: true,
                )
                .snapshots(),
            builder: (context, snap) {
              if (snap.connectionState ==
                  ConnectionState.waiting) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }

              if (!snap.hasData ||
                  snap.data!.docs.isEmpty) {
                return Center(
                  child: Text(
                    'No pending uploads',
                    style: GoogleFonts.poppins(),
                  ),
                );
              }

              return ListView.builder(
                itemCount: snap.data!.docs.length,
                itemBuilder: (context, i) {
                  var doc = snap.data!.docs[i];
                  var data = doc.data() as Map;

                  final String fileUrl =
                      data['fileUrl']?.toString() ?? '';

                  final String fileName =
                      data['fileName']?.toString() ??
                          data['title']?.toString() ??
                          'Uploaded File';

                  return Card(
                    margin: const EdgeInsets.all(8),
                    child: ListTile(
                      leading: Icon(
                        _getFileIcon(
                          data['fileUrl'] ?? '',
                        ),
                        color: Colors.orange,
                      ),
                      title: Text(
                        data['title'] ?? '',
                      ),
                      subtitle: Text(
                        '${data['course']} • ${data['examType']}\n'
                        'Submitted: ${data['uploadedAt'] != null ? DateFormat('dd MMM').format((data['uploadedAt'] as Timestamp).toDate()) : ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // NEW: View file before decision
                          IconButton(
                            tooltip: 'View File',
                            icon: const Icon(
                              Icons.visibility,
                              color: Colors.blue,
                            ),
                            onPressed: fileUrl.isEmpty
                                ? null
                                : () => _viewPendingFile(
                                      fileUrl,
                                      fileName,
                                    ),
                          ),
                          IconButton(
                            tooltip: 'Approve',
                            icon: const Icon(
                              Icons.check_circle,
                              color: Colors.green,
                            ),
                            onPressed: () =>
                                _approvePending(
                              doc.id,
                              data,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Reject',
                            icon: const Icon(
                              Icons.cancel,
                              color: Colors.red,
                            ),
                            onPressed: () =>
                                _rejectPending(
                              doc.id,
                              data['fileName'],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),

          // TAB 4: SETTINGS + REQUESTS
          Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                Text(
                  'Manage Subjects',
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newSubjectController,
                        decoration: const InputDecoration(
                          labelText: 'New Subject',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.add_circle,
                        color: Color(0xFF00C896),
                        size: 32,
                      ),
                      onPressed: _addSubject,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: subjects
                      .map(
                        (s) => Chip(
                          label: Text(s),
                          deleteIcon:
                              const Icon(Icons.close, size: 18),
                          onDeleted: () =>
                              _deleteSubject(s),
                        ),
                      )
                      .toList(),
                ),
                const Divider(height: 40),
                Text(
                  'User Requests',
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                StreamBuilder<QuerySnapshot>(
                  stream: firestore
                      .collection('requests')
                      .orderBy(
                        'timestamp',
                        descending: true,
                      )
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.connectionState ==
                        ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }

                    if (snap.hasError) {
                      return Text(
                        'Error: ${snap.error}',
                      );
                    }

                    if (!snap.hasData ||
                        snap.data!.docs.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'No requests yet',
                            style: GoogleFonts.poppins(
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      );
                    }

                    return Column(
                      children: snap.data!.docs.map((d) {
                        var data =
                            d.data() as Map<String, dynamic>;

                        return Card(
                          child: ListTile(
                            leading: const Icon(
                              Icons.mail,
                              color: Colors.orange,
                            ),
                            title: Text(
                              data['subject'] ??
                                  'No Subject',
                              style: GoogleFonts.poppins(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '${data['message'] ?? ''}\n'
                              '${data['timestamp'] != null ? DateFormat('dd MMM, hh:mm a').format((data['timestamp'] as Timestamp).toDate()) : ''}',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.delete,
                                color: Colors.red,
                              ),
                              onPressed: () =>
                                  _deleteRequest(d.id),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                )
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String url) {
    if (url.contains('.pdf')) {
      return Icons.picture_as_pdf;
    }

    if (url.contains('.jpg') ||
        url.contains('.png') ||
        url.contains('.jpeg')) {
      return Icons.image;
    }

    if (url.contains('.docx')) {
      return Icons.description;
    }

    return Icons.insert_drive_file;
  }
}