library;

export 'src/video_model_client.dart';
export 'src/playback_device.dart';
export 'src/catalog.dart';
export 'src/ranking.dart';

// 多源适配器（P0 骨架）。新增源只改 sources.dart 工厂清单。
export 'src/source_id.dart';
export 'src/source_adapter.dart';
export 'src/source_registry.dart';
export 'src/media_url_policy.dart';
export 'src/routing_catalog.dart';
export 'src/source_resolver.dart';
export 'src/sources/sources.dart';

export 'src/network_retry.dart';
export 'src/upstream_failure.dart';
export 'src/playback_routes.dart';
export 'src/v5_playback.dart';

export 'src/request_control.dart'
    show
        CatalogRequestScope,
        RequestCancelled,
        MetadataDeadlineExceeded,
        MetadataTiming;
