import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/vm_platform.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> with WidgetsBindingObserver {
  static const _kSdcardPath = 'sdcard_path';
  static const _defaultSdcardPath = '/storage/emulated/0/LinxrShare';

  String _sharedPath = _defaultSdcardPath;
  List<FileSystemEntity> _files = [];
  bool _isLoading = true;
  bool _hasPermission = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissionAndLoadFiles();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Recheck permission and reload files when returning from settings
      _checkPermissionAndLoadFiles();
    }
  }

  Future<void> _checkPermissionAndLoadFiles() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      _sharedPath = prefs.getString(_kSdcardPath) ?? _defaultSdcardPath;

      // We request permission, or see if we already have it.
      // On Android 11+, we check if we can read the dir. If we can't,
      // we request the user's permission via our platform channel.
      final dir = Directory(_sharedPath);
      bool permitted = false;

      try {
        if (await dir.exists()) {
          // Try to list files to verify read permission
          dir.listSync();
          permitted = true;
        } else {
          // Try to create the directory to verify write permission
          await dir.create(recursive: true);
          permitted = true;
        }
      } catch (_) {
        permitted = false;
      }

      if (!permitted) {
        // If not permitted directly, let's call the platform channel check
        permitted = await VmPlatform.requestAllFilesAccess();
      }

      setState(() {
        _hasPermission = permitted;
      });

      if (permitted) {
        await _loadFiles();
      } else {
        setState(() {
          _isLoading = false;
          _files = [];
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _loadFiles() async {
    try {
      final dir = Directory(_sharedPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final List<FileSystemEntity> entities = [];
      await for (final entity in dir.list(followLinks: false)) {
        // Only list files for simplicity in the shared folder,
        // or files and directories. Let's include both but focus on files.
        entities.add(entity);
      }

      // Sort by modified date descending, or name. Let's sort by modified date descending.
      final fileStats = <FileSystemEntity, DateTime>{};
      for (final entity in entities) {
        try {
          final stat = await entity.stat();
          fileStats[entity] = stat.modified;
        } catch (_) {
          fileStats[entity] = DateTime.fromMillisecondsSinceEpoch(0);
        }
      }

      entities.sort((a, b) {
        final dateA = fileStats[a] ?? DateTime.fromMillisecondsSinceEpoch(0);
        final dateB = fileStats[b] ?? DateTime.fromMillisecondsSinceEpoch(0);
        return dateB.compareTo(dateA); // newest first
      });

      setState(() {
        _files = entities;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load files: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    final granted = await VmPlatform.requestAllFilesAccess();
    if (granted) {
      _checkPermissionAndLoadFiles();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enable "All files access" in Settings to manage shared files'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _importFile() async {
    final controller = TextEditingController();
    final fileName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Add / Create File', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'filename.txt',
            hintStyle: TextStyle(color: Colors.white24),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) {
                Navigator.pop(context, text);
              }
            },
            child: const Text('Create File'),
          ),
        ],
      ),
    );

    if (fileName == null || fileName.isEmpty) return;

    try {
      setState(() => _isLoading = true);
      final newFile = File('$_sharedPath/$fileName');
      if (!await newFile.exists()) {
        await newFile.writeAsString('');
      }
      await _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File "$fileName" created'),
            backgroundColor: AppColors.secondary,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create file: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  Future<void> _deleteFile(FileSystemEntity entity) async {
    final name = entity.path.split('/').last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete File', style: TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to delete "$name"?',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      setState(() => _isLoading = true);
      await entity.delete(recursive: true);
      await _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File deleted'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete file: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  Future<void> _openSystemManager() async {
    // Attempt to open the directory using external storage Uri
    final folderName = _sharedPath.replaceFirst('/storage/emulated/0/', '');
    final uriString = 'content://com.android.externalstorage.documents/document/primary%3A${Uri.encodeComponent(folderName)}';
    try {
      final uri = Uri.parse(uriString);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        // Fallback: primary root
        final fallbackUri = Uri.parse('content://com.android.externalstorage.documents/root/primary');
        if (await canLaunchUrl(fallbackUri)) {
          await launchUrl(fallbackUri);
        } else {
          throw 'No app found to open files folder';
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open system file manager: $e'),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
              textColor: AppColors.primary,
            ),
          ),
        );
      }
    }
  }

  String _formatSize(int bytes) {
    double size = bytes.toDouble();
    int unitIndex = 0;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  String _formatDateTime(DateTime dt) {
    final y = dt.year;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Widget _buildFileIcon(FileSystemEntity entity) {
    if (entity is Directory) {
      return const Icon(Icons.folder, color: AppColors.warning, size: 28);
    }
    final name = entity.path.toLowerCase();
    if (name.endsWith('.zip') || name.endsWith('.tar') || name.endsWith('.gz') || name.endsWith('.tgz')) {
      return const Icon(Icons.archive, color: AppColors.primary, size: 28);
    } else if (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png') || name.endsWith('.gif') || name.endsWith('.webp')) {
      return const Icon(Icons.image, color: AppColors.secondary, size: 28);
    } else if (name.endsWith('.mp3') || name.endsWith('.wav') || name.endsWith('.ogg') || name.endsWith('.m4a')) {
      return const Icon(Icons.audio_file, color: Colors.purpleAccent, size: 28);
    } else if (name.endsWith('.mp4') || name.endsWith('.mkv') || name.endsWith('.webm') || name.endsWith('.avi')) {
      return const Icon(Icons.video_file, color: Colors.redAccent, size: 28);
    } else if (name.endsWith('.pdf')) {
      return const Icon(Icons.picture_as_pdf, color: AppColors.danger, size: 28);
    } else if (name.endsWith('.txt') || name.endsWith('.md') || name.endsWith('.json') || name.endsWith('.yaml') || name.endsWith('.sh')) {
      return const Icon(Icons.description, color: Colors.blueGrey, size: 28);
    }
    return const Icon(Icons.insert_drive_file, color: Colors.white54, size: 28);
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final folderName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Create New Folder', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Folder Name',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.primary),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.of(context).pop(name);
              }
            },
            child: const Text('Create', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );

    if (folderName == null || folderName.isEmpty) return;

    try {
      setState(() => _isLoading = true);
      final newDir = Directory('$_sharedPath/$folderName');
      if (!await newDir.exists()) {
        await newDir.create(recursive: true);
      }
      await _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Folder "$folderName" created'),
            backgroundColor: AppColors.secondary,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create folder: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shared Files'),
        centerTitle: false,
        actions: [
          if (_hasPermission)
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open in system manager',
              onPressed: _openSystemManager,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _checkPermissionAndLoadFiles,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _hasPermission && !_isLoading
          ? Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'btn_create_folder',
                  onPressed: _createFolder,
                  backgroundColor: AppColors.surface,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.create_new_folder),
                  label: const Text('New Folder'),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.extended(
                  heroTag: 'btn_import_files',
                  onPressed: _importFile,
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.add),
                  label: const Text('Import Files'),
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_hasPermission) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.folder_off, size: 80, color: Colors.white24),
            const SizedBox(height: 24),
            const Text(
              'Permission Required',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              'Linxr needs "All files access" permission to manage files in the configured folder:\n"$_sharedPath"\nand share them with the VM.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _requestPermission,
              icon: const Icon(Icons.settings),
              label: const Text('Grant Access in Settings'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 60, color: AppColors.danger),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _checkPermissionAndLoadFiles,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder_open, size: 80, color: Colors.white12),
              const SizedBox(height: 16),
              const Text(
                'Folder is Empty',
                style: TextStyle(color: Colors.white54, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Files placed here will be available to the VM at /mnt/sdcard.\nConfigure this folder in Settings.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 13, height: 1.4),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _createFolder,
                    icon: const Icon(Icons.create_new_folder),
                    label: const Text('New Folder'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surface,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _importFile,
                    icon: const Icon(Icons.file_upload),
                    label: const Text('Import Files'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: AppColors.surface,
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: Colors.white38),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Path: $_sharedPath',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: _files.length,
            separatorBuilder: (context, index) => const Divider(height: 1, color: Colors.white10),
            itemBuilder: (context, index) {
              final entity = _files[index];
              final name = entity.path.split('/').last;

              return FutureBuilder<FileStat>(
                future: entity.stat(),
                builder: (context, snapshot) {
                  final stat = snapshot.data;
                  final sizeStr = stat != null && entity is File ? _formatSize(stat.size) : '';
                  final dateStr = stat != null ? _formatDateTime(stat.modified) : '';

                  return ListTile(
                    leading: _buildFileIcon(entity),
                    title: Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Row(
                      children: [
                        if (sizeStr.isNotEmpty) ...[
                          Text(sizeStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                          const SizedBox(width: 12),
                        ],
                        if (dateStr.isNotEmpty)
                          Text(dateStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.white38, size: 20),
                      onPressed: () => _deleteFile(entity),
                    ),
                    onTap: () async {
                      if (entity is File) {
                        try {
                          final file = entity as File;
                          final bytes = await file.readAsBytes();
                          String textContent;
                          try {
                            textContent = utf8.decode(bytes);
                            if (textContent.length > 5000) {
                              textContent = '${textContent.substring(0, 5000)}\n\n[Truncated...]';
                            }
                          } catch (_) {
                            textContent = 'Binary file (Size: ${bytes.length} bytes)';
                          }

                          if (!mounted) return;
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: AppColors.surface,
                              title: Text(name, style: const TextStyle(color: Colors.white)),
                              content: SingleChildScrollView(
                                child: Text(
                                  textContent,
                                  style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 13),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Close', style: TextStyle(color: AppColors.primary)),
                                ),
                              ],
                            ),
                          );
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error reading file: $e'),
                                backgroundColor: AppColors.danger,
                              ),
                            );
                          }
                        }
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
