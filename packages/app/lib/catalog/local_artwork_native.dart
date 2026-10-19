import 'dart:io';

import 'package:flutter/painting.dart';

ImageProvider? localArtwork(String? path) =>
    path == null ? null : FileImage(File(path));
