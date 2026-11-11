import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/auth/peer_fingerprint_middleware.dart';
import '../../core/common/app_logger.dart';
import '../../core/common/key_value_store.dart';
import '../../core/database/app_database.dart';
import '../../core/device/device_file_service.dart';
import '../../core/device/local_pick_facade.dart';
import '../../core/device/permission_service.dart';
import '../../core/device/local_basics.dart';
import '../../core/discovery/discovery_foreground_guard.dart';
import '../../core/discovery/discovery_service.dart';
import '../../core/storage/local_system_stats.dart';
import '../../core/discovery/peer_registry.dart';
import '../../core/discovery/platform_multicast_lock.dart';
import '../../core/host/http_host_service.dart';
import '../../core/host/nas_route_guard.dart';
import '../../core/identity/device_identity_service.dart';
import '../../core/identity/identity_key_store.dart';
import '../../core/identity/migrations.dart' as identity;
import '../../core/identity/peer.dart';
import '../../core/identity/peer_repository.dart';
import '../../core/identity/stable_device_id.dart';
import '../../core/identity/tls_certificate_manager.dart';
import '../../core/network/local_ipv4.dart';
import '../../core/network/peer_address.dart';
import '../../core/nas/nas_keep_alive.dart';
import '../../core/nas/shared_replica_store.dart';
import '../../core/network/peer_api_client.dart';
import '../../core/pairing/pairing_services.dart';
import '../../core/realtime/peer_runtime_store.dart';
import '../../core/realtime/peer_status_service.dart';
import '../../core/realtime/peer_ws_session.dart';
import '../../core/realtime/realtime_connection_registry.dart';
import '../../core/realtime/realtime_hub.dart';
import '../../core/realtime/realtime_session_service.dart';
import '../../core/storage/media_library_service.dart';
import '../../core/storage/nas_peer_preview_cache.dart';
import '../../core/storage/share_reader.dart';
import '../../core/storage/share_writer.dart';
import '../../core/storage/storage_root_store.dart';
import '../../core/storage/switch_share_root.dart';
import '../../core/task/transfer_task_store.dart';
import '../../core/transfer/nas_transfer_service.dart';
import '../../features/devices/application/chat_unread_store.dart';
import '../../features/devices/application/offer_accept_service.dart';
import '../../features/devices/data/datasources/chat_local_data_source.dart';
import '../../features/devices/data/host_endpoints/pairing_endpoint.dart';
import '../../features/devices/data/host_endpoints/ping_endpoint.dart';
import '../../features/devices/data/host_endpoints/transfer_endpoints.dart';
import '../../features/devices/data/repositories/chat_repository.dart';
import '../../features/nas/application/nas_service_switch.dart';
import '../../features/nas/application/start_nas_service_use_case.dart';
import '../../features/nas/application/stop_nas_service_use_case.dart';
import '../../features/nas/data/api/services/thumbnail_service.dart';
import '../../core/storage/backup_receive_service.dart';
import '../../core/storage/inbox_catalog_service.dart';
import '../../features/backup/application/backup_engine.dart';
import '../../features/backup/data/backup_local_store.dart';
import '../../features/backup/data/backup_migrations.dart';
import '../../features/devices/application/category_download_engine.dart';
import '../../features/devices/data/category_download_store.dart';
import '../../features/backup/data/backup_remote_client.dart';
import '../../features/nas/data/nas_share_scope.dart';
import '../../features/nas/data/share_path_resolver.dart';
import '../../features/nas/presentation/cubits/nas_control_cubit.dart';
import 'modules/nas_host_routes.dart';

/// Central dependency registry (core services register first).
/// 阶段 1：数据库 + TLS 身份 + peer 表 + 配对（扫码/密码）+ 最小宿主。
Future<void> configureDependencies({
  required KeyValueStore keyValueStore,
}) async {
  await ServiceLocator().init(
    keyValueStore: keyValueStore,
    hostPort: defaultHostPort,
  );
}

/// 宿主默认端口（doc/04 §3.2：端口可在概览下拉改）。
const defaultHostPort = 5244;

class ServiceLocator {
  static final ServiceLocator _instance = ServiceLocator._internal();
  factory ServiceLocator() => _instance;
  ServiceLocator._internal();

  KeyValueStore? _keyValueStore;
  DeviceIdentityService? _deviceIdentityService;
  StableDeviceIdService? _stableDeviceIdService;

  // 懒初始化缓存 Future 而非结果：bootstrap 的 fire-and-forget 宿主链路
  // 与 UI 触发的同服务并发调用共享同一 Future——否则竞态下会构造两个
  // AppDatabase，MigrationRegistry 二次注册同版本迁移即崩。
  Future<Database>? _sqliteFuture;
  Future<PeerRepository>? _peerRepositoryFuture;
  Future<PairingHostService>? _pairingHostServiceFuture;
  Future<PairingClientService>? _pairingClientServiceFuture;
  Future<HttpHostService>? _hostServiceFuture;
  HttpHostService? _hostService;
  Router? _hostRouter;
  Future<void>? _transferStackFuture;
  bool _transferStackMounted = false;
  bool _deferredStartupStarted = false;

  /// announce 载荷 pend 粗提示缓存（真相源仍是 pending 端点）。
  int _announcePendCount = 0;
  DiscoveryService? _discoveryService;
  PeerRegistry? _peerRegistry;
  PeerApiClient? _peerApiClient;
  StorageRootStore? _storageRootStore;
  SharedReplicaStore? _sharedReplicaStore;
  SwitchShareRoot? _switchShareRoot;
  ShareWriter? _shareWriter;
  ShareReader? _shareReader;
  MediaLibraryService? _mediaLibraryService;
  NasServiceSwitch? _nasServiceSwitch;
  NasControlCubit? _nasControlCubit;
  SharePathResolver? _sharePathResolver;
  NasShareScope? _nasShareScope;
  ThumbnailService? _thumbnailService;
  BackupReceiveService? _backupReceive;
  BackupEngine? _backupEngine;
  BackupLocalStore? _backupLocalStore;
  CategoryDownloadEngine? _categoryDownloadEngine;
  CategoryDownloadStore? _categoryDownloadStore;
  InboxCatalogService? _inboxCatalog;
  bool _nasStackMounted = false;
  Future<TransferTaskStore>? _transferTaskStoreFuture;
  Future<ChatRepository>? _chatRepositoryFuture;
  RealtimeConnectionRegistry? _realtimeRegistry;
  RealtimeHub? _realtimeHub;
  RealtimeSessionService? _realtimeSession;
  PeerRuntimeStore? _peerRuntimeStore;
  PeerStatusService? _peerStatusService;
  PeerWsSession? _peerWsSession;
  LocalSystemStatsSource? _localSystemStatsSource;
  Future<OfferAcceptService>? _offerAcceptFuture;
  OfferAcceptService? _offerAcceptService;
  ChatUnreadStore? _chatUnreadStore;
  LocalBasics? _localBasics;
  PermissionService? _permissionService;
  DeviceFileService? _deviceFileService;
  LocalPickFacade? _localPickFacade;
  NasTransferService? _nasTransferService;
  Timer? _sweepTimer;
  StreamSubscription<AnnouncePayload>? _announceSubscription;
  DiscoveryForegroundGuard? _discoveryGuard;
  bool _discoveryBindingsReady = false;
  bool _discoveryFailurePrompted = false;

  /// UDP 冷启网络守卫（docs/设备探测与在线状态维护.md §3.2–3.3）。
  StreamSubscription<List<ConnectivityResult>>? _discoveryNetSub;
  Timer? _discoveryNetDebounce;
  Timer? _rxWatchdog;
  bool _discoveryNetGuardStarted = false;
  bool _hadLanConnectivity = false;
  DateTime? _lastDiscoveryJoinAt;
  static const _resumeColdStartMin = Duration(seconds: 45);
  static const _rxWatchdogPeriod = Duration(minutes: 15);
  static const _discoveryNetDebounceDelay = Duration(milliseconds: 400);
  static const _offlineProbeMaxConcurrent = 3;

  int _hostPort = defaultHostPort;
  String? _hostAddress;
  Future<String>? _addressFuture;

  static const _kPreferredIpv4 = 'network.preferred_ipv4';

  /// 本机局域网 IP（概览多网卡选择 / 换网刷新后通知 UI）。
  final ValueNotifier<String> hostAddressListenable = ValueNotifier('0.0.0.0');

  /// 组播 ensure 失败时由根组件弹窗（null=无需提示）。
  final ValueNotifier<DiscoveryEnsureResult?> discoveryAlert =
      ValueNotifier(null);

  Future<void> init({
    required KeyValueStore keyValueStore,
    required int hostPort,
  }) async {
    _keyValueStore = keyValueStore;
    _hostPort = keyValueStore.getInt(_kHostPort) ?? hostPort;
    NasKeepAlive.ensureHost = ensureUiHost;
    unawaited(sharedReplicaStore().warmLocalGeneration());
    // 地址探测放到 runDeferredStartup（首帧后），不挡 DI
    _localBasics ??= LocalBasics(
      refreshAddress: refreshLocalAddress,
      readStats: () => localSystemStatsSource().read(),
      currentAddress: () => hostAddress,
      onAddressChanged: () {
        // 网卡抖动后组播 JOIN 常失效；仅 announce 不够，需 rebuild。
        unawaited(healDiscoveryAfterNetworkChange());
      },
    );
    _localBasics!.start();
  }

  /// 本机基本信息（IP + 内存/存储）；见 doc/基本信息采集刷新机制.md。
  LocalBasics get localBasics => _localBasics!;

  /// 概览 Tab 是否为当前页（IndexedStack 下页不销毁，用此冻结订阅）。
  final ValueNotifier<bool> overviewVisible = ValueNotifier(true);

  /// 设备 Tab 是否为当前页。
  final ValueNotifier<bool> devicesVisible = ValueNotifier(false);

  /// 已配对设备全局通知（概览/设备两页共用；阶段 2 被 PeerRegistry
  /// 在线流正式替代——阶段 1 最小可见性方案）。
  ///
  /// 配对成功 / 吊销后调 [refreshPairedPeers] 推送最新 peer 列表，
  /// 页面用 ValueListenableBuilder 监听。
  final ValueNotifier<List<Peer>> pairedPeers = ValueNotifier([]);

  /// 重读 peer 表并广播（静默失败保空表——DB 不可用时 UI 退化为空态）。
  Future<void> refreshPairedPeers() async {
    try {
      final repository = await peerRepository();
      pairedPeers.value = await repository.getAll();
    } catch (_) {}
  }

  KeyValueStore get keyValueStore => _keyValueStore!;

  int get hostPort => _hostPort;

  static const _kHostPort = 'host.listen_port';

  /// 修改监听端口并重启宿主（即时生效；announce 同步新端口）。
  Future<void> setHostPort(int port) async {
    if (port < 1024 || port > 65535) {
      throw ArgumentError('port out of range');
    }
    if (port == _hostPort) return;
    await _keyValueStore?.setInt(_kHostPort, port);
    _hostPort = port;

    final old = _hostService;
    _hostService = null;
    _hostServiceFuture = null;
    // 路由表可复用；仅重建监听
    final router = _hostRouter;
    if (old != null) {
      await old.stop();
    }
    if (router != null) {
      final host = HttpHostService(
        port: _hostPort,
        securityContext: deviceIdentityService.serverSecurityContext(),
        publicRoutes: router,
        middlewares: [
          peerFingerprintMiddleware(
            peerLookup: (fingerprint) async =>
                (await peerRepository()).findByFingerprint(fingerprint),
            exemptPaths: {
              PairingEndpoint.path,
              PairPasswordEndpoint.path,
            },
          ),
          nasRouteGuard(isEnabled: () => isNasServiceEnabled),
        ],
      );
      _hostService = host;
      _hostServiceFuture = Future.value(host);
      await host.start();
    }
    discoveryService().announceNow();
    AppLogger.log(
      'host port changed',
      scope: 'host',
      details: {'port': _hostPort},
    );
  }

  /// 同步缓存地址（探测未完成时为回退值；概览展示按需用 [resolvedAddress]）。
  String get hostAddress => _hostAddress ?? hostAddressListenable.value;

  /// 探测完成后的地址（宿主/二维码等需要准确地址的链路 await 此值）。
  Future<String> get resolvedAddress async {
    final future = _addressFuture;
    if (future != null) {
      _hostAddress = await future;
    }
    return _hostAddress ?? '0.0.0.0';
  }

  /// 枚举本机 IPv4（多网卡 UI）。
  Future<List<LocalIpv4Candidate>> listLocalIpv4() =>
      listLocalIpv4Candidates();

  /// 重新探测并选定本机 IP（保留用户偏好，若仍在列表中）。
  Future<String> refreshLocalAddress() async {
    final candidates = await listLocalIpv4Candidates();
    final preferred = _keyValueStore?.getString(_kPreferredIpv4);
    late final String chosen;
    if (preferred != null &&
        preferred.isNotEmpty &&
        candidates.any((c) => c.address == preferred)) {
      chosen = preferred;
    } else if (candidates.isNotEmpty) {
      chosen = candidates.first.address;
    } else {
      chosen = '0.0.0.0';
    }
    _applyHostAddress(chosen);
    return chosen;
  }

  /// 用户选定用于二维码 / UDP 广播的本机 IP。
  Future<void> selectLocalAddress(String address) async {
    await _keyValueStore?.setString(_kPreferredIpv4, address);
    _applyHostAddress(address);
    _addressFuture = Future.value(address);
    await sharedReplicaStore().commit(reason: 'preferred_ipv4');
    await announceNowRouted();
  }

  void _applyHostAddress(String address) {
    _hostAddress = address;
    hostAddressListenable.value = address;
  }

  /// 单库（app.db）：identity v1–v2 + task v3 + chat v4 + stable_id v5 + backup v6 + brand v7 + emoji v8 + 分类下载 v9。
  Future<Database> sqlite() {
    return _sqliteFuture ??= () async {
      final appDb = AppDatabase(migrations: [
        ...identity.identityMigrations,
        ...taskMigrations,
        ...chatMigrations,
        identity.identityStableIdMigration,
        ...backupMigrations,
        identity.identityBrandMigration,
        identity.identityEmojiMigration,
        ...categoryDownloadMigrations,
      ]);
      return appDb.database;
    }();
  }

  /// 冷总线世代（docs/FGS与UI双引擎数据同步策略.md）。
  SharedReplicaStore sharedReplicaStore() {
    if (_sharedReplicaStore != null) return _sharedReplicaStore!;
    final store = SharedReplicaStore(keyValueStore: keyValueStore);
    store.onApply = applySharedReplica;
    _sharedReplicaStore = store;
    return store;
  }

  Future<void> _commitSharedReplica(String reason) =>
      sharedReplicaStore().commit(reason: reason);

  /// 冷总线对侧失效后的派生刷新（不清票 / 不拆宿主）。
  Future<void> applySharedReplica(String reason) async {
    await keyValueStore.reload();
    deviceIdentityService.reloadDisplayFromStore();
    // 存储根靠 ensureCurrent → _syncFromDiskIfNeeded；此处预热一次。
    try {
      await storageRootStore().ensureCurrent();
    } catch (_) {}
    if (reason.contains('ipv4') ||
        reason.contains('identity') ||
        reason == 'preferred_ipv4' ||
        reason.startsWith('identity')) {
      try {
        await refreshLocalAddress();
      } catch (_) {}
    }
    try {
      await announceNowRouted();
    } catch (_) {}
    if (reason.contains('peer') || reason == 'peers') {
      await applyPeersDirty();
    }
  }

  /// 热总线：peers 名册重载（SQLite 已是真相）。
  Future<void> applyPeersDirty() async {
    await refreshPairedPeers();
    await peerRegistry().reloadPaired();
  }

  /// 共享根持久化（阶段 2.6a）。
  StorageRootStore storageRootStore() {
    return _storageRootStore ??= StorageRootStore(
      keyValueStore: keyValueStore,
      onPersisted: (reason) => _commitSharedReplica(reason),
    );
  }

  /// 切换共享写根（路径 / OTG；设置页入口）。
  SwitchShareRoot switchShareRoot() {
    return _switchShareRoot ??=
        SwitchShareRoot(rootStore: storageRootStore());
  }

  ShareWriter shareWriter() {
    return _shareWriter ??= ShareWriter(rootStore: storageRootStore());
  }

  ShareReader shareReader() {
    return _shareReader ??= ShareReader(rootStore: storageRootStore());
  }

  MediaLibraryService mediaLibraryService() =>
      _mediaLibraryService ??= MediaLibraryService(
        resolveScanRoot: () async {
          final root = await storageRootStore().ensureCurrent();
          return Directory(root.uriOrPath);
        },
      );

  PermissionService permissionService() =>
      _permissionService ??= PermissionService();

  DeviceFileService deviceFileService() =>
      _deviceFileService ??= DeviceFileService();

  /// 本地选文件门面（相册 + 任意文件 path）。
  LocalPickFacade localPickFacade() => _localPickFacade ??= LocalPickFacade(
        deviceFiles: deviceFileService(),
        permissions: permissionService(),
      );

  /// 传输任务表。
  Future<TransferTaskStore> transferTaskStore() {
    return _transferTaskStoreFuture ??= () async {
      final sqlite = await this.sqlite();
      return TransferTaskStore(db: () => sqlite);
    }();
  }

  /// NAS 上传/下载编排。
  NasTransferService nasTransferService() {
    return _nasTransferService ??= NasTransferService(
      tasks: transferTaskStore,
      api: peerApiClient(),
      writer: shareWriter(),
    );
  }

  Future<ChatRepository> chatRepository() {
    return _chatRepositoryFuture ??= () async {
      final sqlite = await this.sqlite();
      return ChatRepository(
        local: ChatLocalDataSource(db: () => sqlite),
      );
    }();
  }

  RealtimeConnectionRegistry realtimeRegistry() {
    return _realtimeRegistry ??= RealtimeConnectionRegistry();
  }

  LocalSystemStatsSource localSystemStatsSource() {
    return _localSystemStatsSource ??= LocalSystemStatsSource();
  }

  PeerRuntimeStore peerRuntimeStore() {
    return _peerRuntimeStore ??= PeerRuntimeStore();
  }

  PeerStatusService peerStatusService() {
    // 先确保 session 实例存在，再挂 status（避免循环构造）。
    realtimeSession();
    return _peerStatusService ??= PeerStatusService(
      runtimeStore: peerRuntimeStore(),
      hubRegistry: realtimeRegistry(),
      session: () => _realtimeSession!,
      identityService: deviceIdentityService,
      statsSource: localSystemStatsSource(),
      peerRepository: peerRepository,
      onPeerStaticUpdated: refreshPairedPeers,
    )..start();
  }

  /// 对端聊天 / NAS 共用出站 WS 会话门面。
  PeerWsSession peerWsSession() {
    return _peerWsSession ??= PeerWsSession(
      session: realtimeSession,
      ensureHostRunning: ensureHostRunning,
    );
  }

  RealtimeSessionService realtimeSession() {
    final fp = deviceIdentityService.cachedIdentity?.fingerprint ?? '';
    final cached = _realtimeSession;
    if (cached == null || cached.selfFingerprint != fp) {
      unawaited(cached?.dispose() ?? Future.value());
      _realtimeSession = RealtimeSessionService(
        peerRepository: peerRepository,
        selfFingerprint: fp,
        onPeerConnected: (peerFp) {
          // 避免 ?. 丢掉首帧：回调时确保 status 服务已挂上
          peerStatusService().onPeerConnected(peerFp);
        },
        onPeerDisconnected: (peerFp) {
          _peerStatusService?.onPeerDisconnected(peerFp);
        },
      );
      // 指纹轮换后重建 status 订阅（session 已赋值，可立刻重建）
      _peerStatusService?.dispose();
      _peerStatusService = null;
    }
    return _realtimeSession!;
  }

  RealtimeHub realtimeHub() {
    return _realtimeHub ??= RealtimeHub(
      registry: realtimeRegistry(),
      onEvent: (fp, event) async {
        await peerStatusService().handleInbound(fp, event);
        final svc = await offerAcceptService();
        await svc.handleInboundEvent(fp, event);
      },
      onPeerConnected: (fp) => peerStatusService().onPeerConnected(fp),
      onPeerDisconnected: (fp) => peerStatusService().onPeerDisconnected(fp),
    );
  }

  ChatUnreadStore chatUnreadStore() {
    return _chatUnreadStore ??= ChatUnreadStore(
      onUnreadDelta: (fp, op) {
        unawaited(_publishUnreadDelta(fp, op));
      },
    );
  }

  Future<void> _publishUnreadDelta(String fingerprint, String op) async {
  }

  /// 互传编排（懒异步单例）。
  Future<OfferAcceptService> offerAcceptService() {
    return _offerAcceptFuture ??= () async {
      // 身份指纹就绪后再建 session
      await deviceIdentityService.identity;
      final unread = chatUnreadStore();
      final service = OfferAcceptService(
        taskStore: await transferTaskStore(),
        chatRepository: await chatRepository(),
        peerApiClient: peerApiClient(),
        shareWriter: shareWriter(),
        session: realtimeSession(),
        hubRegistry: realtimeRegistry(),
        ensurePeerWs: (fp) => peerWsSession().enter(fp),
        onInboundChatActivity: unread.mark,
        onOutboxChanged: refreshAnnouncePend,
      );
      service.attachSessionEvents();
      _offerAcceptService = service;
      return service;
    }();
  }

  /// 同步取已就绪实例（未就绪则抛错；UI 应 await [offerAcceptService]）。
  OfferAcceptService requireOfferAcceptService() {
    final s = _offerAcceptService;
    if (s == null) {
      throw StateError('OfferAcceptService not ready');
    }
    return s;
  }

  /// peer 表仓库（信任模型核心）。
  Future<PeerRepository> peerRepository() {
    return _peerRepositoryFuture ??= () async {
      final sqlite = await this.sqlite();
      return PeerRepository(
        db: () => sqlite,
        onFingerprintSuperseded: (from, to) {
          peerRuntimeStore().clear(from);
          peerRegistry().markUnreachable(from);
          peerApiClient().invalidate(from);
          AppLogger.log(
            'fingerprint superseded',
            scope: 'identity',
            details: {
              'from': from.substring(0, 8),
              'to': to.substring(0, 8),
            },
          );
        },
      );
    }();
  }

  /// 设备身份（含 TLS 指纹=Device ID）。首次访问触发证书加载/生成。
  DeviceIdentityService get deviceIdentityService {
    _deviceIdentityService ??= DeviceIdentityService(
      certificateManager: TlsCertificateManager(
        keyStore: const IdentityKeyStore(),
      ),
      keyValueStore: keyValueStore, // 批次 E：改名持久化
    );
    return _deviceIdentityService!;
  }

  /// 物理设备稳定线索（重装认旧；不参与授权）。
  StableDeviceIdService get stableDeviceIdService {
    return _stableDeviceIdService ??= StableDeviceIdService();
  }

  /// 被配对侧服务（生成二维码/密码 + enroll 处理）。
  Future<PairingHostService> pairingHostService() {
    return _pairingHostServiceFuture ??= () async {
      final identityService = deviceIdentityService;
      final stableIds = stableDeviceIdService;
      return PairingHostService(
        peerRepository: await peerRepository(),
        keyValueStore: keyValueStore,
        identity: () async {
          final i = await identityService.identity;
          final sid = await stableIds.stableIdHash();
          return (
            fingerprint: i.fingerprint,
            name: i.deviceName,
            brand: i.brand,
            model: i.model,
            stableIdHash: sid,
          );
        },
        localAddress: () => hostAddress,
        port: () => hostPort,
        onPeerWritten: (peer) => onPairingSettled(peer),
      );
    }();
  }

  /// 发起侧服务（扫码/密码 enroll 上报）。
  Future<PairingClientService> pairingClientService() {
    return _pairingClientServiceFuture ??= () async {
      return PairingClientService(
        peerRepository: await peerRepository(),
      );
    }();
  }

  /// 确保常驻宿主已监听（配对前调用，避免尚未 bind 就 enroll）。
  ///
  /// 仅 UI isolate：FGS 已接管时跳过。FGS isolate 自身不得跳过。
  Future<void> ensureHostRunning() async {
    if (_keyValueStore == null) return; // DI 未就绪（单测）时跳过
    final host = await hostService();
    if (!host.isRunning) {
      await host.start();
    }
  }

  /// 确保本进程 HTTPS 宿主与发现在跑（Windows 单进程，无 FGS 交接）。
  Future<void> ensureUiHost() async {
    try {
      final host = await hostService();
      if (!host.isRunning) await host.start();
    } catch (e, st) {
      AppLogger.log(
        'ensure UI host failed',
        scope: 'host',
        error: e,
        stackTrace: st,
      );
    }
    try {
      await ensureDiscovery(rebuild: true);
    } catch (e, st) {
      AppLogger.log(
        'ensure UI discovery failed',
        scope: 'discovery',
        error: e,
        stackTrace: st,
      );
    }
  }

  bool get isHostRunning => _hostService?.isRunning ?? false;

  int? get boundHostPort => _hostService?.boundPort;

  /// 最小常驻宿主：配对 + ping + device-info（不含传文件栈）。
  Future<HttpHostService> hostService() {
    return _hostServiceFuture ??= () async {
      final router = Router();
      final pairing = await pairingHostService();

      router.post(
        PairingEndpoint.path,
        PairingEndpoint(hostService: pairing).handler,
      );
      router.post(
        PairPasswordEndpoint.path,
        PairPasswordEndpoint(hostService: pairing).handler,
      );
      router.get(
        PingEndpoint.path,
        PingEndpoint(identityService: deviceIdentityService).handler,
      );
      router.get(
        DeviceInfoEndpoint.path,
        DeviceInfoEndpoint(
          identityService: deviceIdentityService,
          nasEnabled: () => isNasServiceEnabled,
        ).handler,
      );

      _hostRouter = router;
      _mountNasStack(router);
      final host = HttpHostService(
        port: hostPort,
        securityContext: deviceIdentityService.serverSecurityContext(),
        publicRoutes: router,
        middlewares: [
          peerFingerprintMiddleware(
            peerLookup: (fingerprint) async =>
                (await peerRepository()).findByFingerprint(fingerprint),
            exemptPaths: {
              PairingEndpoint.path,
              PairPasswordEndpoint.path,
            },
          ),
          nasRouteGuard(isEnabled: () => isNasServiceEnabled),
        ],
      );
      _hostService = host;
      return host;
    }();
  }

  /// NAS 路由集静态挂载（开关关时由 [nasRouteGuard] 返回 503，不卸载）。
  void _mountNasStack(Router router) {
    if (_nasStackMounted) return;
    mountNasHostRoutes(
      router: router,
      shareReader: shareReader(),
      sharePathResolver: sharePathResolver(),
      thumbnailService: thumbnailService(),
      mediaLibrary: mediaLibraryService(),
      inboxCatalog: inboxCatalogService(),
      backupReceive: backupReceiveService(),
      shareScope: nasShareScope(),
    );
    _nasStackMounted = true;
  }

  SharePathResolver sharePathResolver() =>
      _sharePathResolver ??= SharePathResolver(rootStore: storageRootStore());

  NasShareScope nasShareScope() =>
      _nasShareScope ??= NasShareScope(
        keyValueStore: keyValueStore,
        onPersisted: () => _commitSharedReplica('share_scope'),
      );

  ThumbnailService thumbnailService() =>
      _thumbnailService ??= ThumbnailService();

  BackupReceiveService backupReceiveService() =>
      _backupReceive ??= BackupReceiveService(
        rootStore: storageRootStore(),
        shareWriter: shareWriter(),
        mediaLibrary: mediaLibraryService(),
      );

  BackupLocalStore backupLocalStore() =>
      _backupLocalStore ??= BackupLocalStore(db: sqlite);

  BackupEngine backupEngine() => _backupEngine ??= BackupEngine(
        store: backupLocalStore(),
        remote: BackupRemoteClient(api: peerApiClient()),
        peerRegistry: peerRegistry(),
      );

  CategoryDownloadStore categoryDownloadStore() =>
      _categoryDownloadStore ??= CategoryDownloadStore(db: sqlite);

  CategoryDownloadEngine categoryDownloadEngine() =>
      _categoryDownloadEngine ??= CategoryDownloadEngine(
        store: categoryDownloadStore(),
        tasks: transferTaskStore,
        transfers: nasTransferService(),
        peers: peerRegistry(),
        api: peerApiClient(),
      );

  InboxCatalogService inboxCatalogService() =>
      _inboxCatalog ??= InboxCatalogService(
        rootStore: storageRootStore(),
        shareWriter: shareWriter(),
        mediaLibrary: mediaLibraryService(),
      );

  /// 挂载传文件 / Chat / WS 路由（幂等）。聊天页、配对完成、已有 peers 时调用。
  Future<void> ensureTransferStack() {
    return _transferStackFuture ??= () async {
      await hostService();
      final router = _hostRouter;
      if (router == null) {
        throw StateError('host router missing');
      }
      if (_transferStackMounted) return;

      final tasks = await transferTaskStore();
      final offers = await offerAcceptService();
      final hub = realtimeHub();

      router.get(
        PendingEndpoint.path,
        PendingEndpoint(taskStore: tasks).handler,
      );
      router.get(
        PayloadEndpoint.path,
        PayloadEndpoint(taskStore: tasks).handler,
      );
      router.get(
        PosterEndpoint.path,
        PosterEndpoint(taskStore: tasks).handler,
      );
      router.post(
        ReceiptEndpoint.path,
        ReceiptEndpoint(offerAccept: offers).handler,
      );
      router.post(
        ChatEndpoint.path,
        ChatEndpoint(offerAccept: offers).handler,
      );
      router.get(RealtimeHub.path, hub.handler);
      _transferStackMounted = true;
    }();
  }

  /// 首帧后延后档：地址 / peers / 最小宿主 / 发现；（有配对时）传文件栈。
  Future<void> runDeferredStartup() async {
    if (_deferredStartupStarted) return;
    _deferredStartupStarted = true;

    await Future.wait<void>([
      refreshLocalAddress().then((_) {
        _addressFuture = Future.value(hostAddress);
      }),
      refreshPairedPeers(),
      deviceIdentityService.identity.then((_) {}),
    ]);

    final nasOn = isNasServiceEnabled;
    if (nasOn) {
      try {
        await NasKeepAlive.sync(true);
        try {
          final result = await ensureDiscovery(rebuild: false);
          _publishDiscoveryResult(result);
        } catch (error, st) {
          AppLogger.log(
            'deferred: discovery FAILED',
            scope: 'boot',
            error: error,
            stackTrace: st,
          );
        }
      } catch (error, st) {
        AppLogger.log(
          'deferred: NAS runtime start FAILED',
          scope: 'boot',
          error: error,
          stackTrace: st,
        );
      }
    } else {
      try {
        final host = await hostService();
        if (!host.isRunning) {
          await host.start();
        }
      } catch (error, st) {
        AppLogger.log(
          'deferred: host start FAILED',
          scope: 'boot',
          error: error,
          stackTrace: st,
        );
      }

      try {
        final result = await ensureDiscovery(rebuild: false);
        _publishDiscoveryResult(result);
      } catch (error, st) {
        AppLogger.log(
          'deferred: discovery FAILED',
          scope: 'boot',
          error: error,
          stackTrace: st,
        );
      }

    }

    // 已有配对设备时提前挂传文件栈，避免停在概览时收不到文件
    // （NAS FGS 侧也会 ensure；UI 侧挂路由表供本机 Cubit 使用无害）
    if (pairedPeers.value.isNotEmpty) {
      unawaited(ensureTransferStack());
    }

    // 对端 NAS 预览缓存：杀进程残留的 active 会话在此扫尾。
    unawaited(
      NasPeerPreviewCache.instance.purgeStaleOnLaunch().catchError(
        (Object e, StackTrace st) {
          AppLogger.log(
            'nas preview cache purge FAILED',
            scope: 'boot',
            error: e,
            stackTrace: st,
          );
        },
      ),
    );

    // 传输任务：冷启动一刀切收尾残留 NAS 上下载，避免底栏/列表挂尸。
    unawaited(nasTransferService().ensureColdStartCleanup());

    // 冷启动：对离线已配对 HTTPS 拉绿（无则跳过）。
    unawaited(probeOfflinePairedPeers());
  }

  /// 发现服务（UDP 组播 announce；依赖身份/地址，懒启动）。
  DiscoveryService discoveryService() {
    return _discoveryService ??= DiscoveryService(
      multicastLock: PlatformMulticastLock(),
      self: () {
        // 同步快照：身份缓存未就绪时指纹字段为空——心跳周期内自愈
        final identity = deviceIdentityService.cachedIdentity;
        final fp = identity?.fingerprint;
        return AnnouncePayload(
          version: 1,
          fingerprint: (fp != null && fp != 'unavailable') ? fp : '',
          name: identity?.deviceName ?? '未知设备',
          brand: identity?.brand ?? '',
          model: identity?.model ?? 'unknown',
          emoji: identity?.emoji ?? '',
          host: hostAddress,
          port: _hostPort,
          pend: _announcePendCount > 0,
          nas: isNasServiceEnabled,
        );
      },
    );
  }

  /// 本机 NAS 服务开关（持久化；announce / info caps 对外宣告）。
  NasServiceSwitch nasServiceSwitch() {
    return _nasServiceSwitch ??= NasServiceSwitch(
      store: keyValueStore,
      onChanged: (_) {
        // FGS 交接由 Start/Stop use case / deferred 显式 await NasKeepAlive.sync。
        // 此处仅尝试 UI 侧补 announce（FGS 接管后 ensureDiscovery 会 no-op）。
        try {
          discoveryService().announceNow();
        } catch (_) {}
      },
      onPersisted: () => _commitSharedReplica('nas_enabled'),
    );
  }

  bool get isNasServiceEnabled => nasServiceSwitch().isEnabled;

  Future<void> setNasServiceEnabled(bool enabled) async {
    await nasServiceSwitch().setEnabled(enabled);
  }

  NasControlCubit nasControlCubit() {
    final sw = nasServiceSwitch();
    return _nasControlCubit ??= NasControlCubit(
      serviceSwitch: sw,
      start: StartNasServiceUseCase(serviceSwitch: sw),
      stop: StopNasServiceUseCase(serviceSwitch: sw),
    );
  }

  /// 在线状态聚合（announce ∩ peers 表；设备页消费）。
  PeerRegistry peerRegistry() {
    return _peerRegistry ??= PeerRegistry(
      pairedPeers: () => pairedPeers.value,
      loadPeers: () async {
        await refreshPairedPeers();
        return pairedPeers.value;
      },
    );
  }

  /// 受信 API 客户端（连接测试/阶段 2 互传）。
  /// 本机指纹用时向 [deviceIdentityService] 解析，避免启动早期空串冻死。
  PeerApiClient peerApiClient() {
    return _peerApiClient ??= PeerApiClient(
      peerRepository: peerRepository,
      resolveSelfFingerprint: () async {
        final cached = deviceIdentityService.cachedIdentity?.fingerprint;
        if (cached != null &&
            cached.isNotEmpty &&
            cached != 'unavailable') {
          return cached;
        }
        try {
          final id = await deviceIdentityService.identity;
          final fp = id.fingerprint;
          if (fp.isEmpty || fp == 'unavailable') return '';
          return fp;
        } catch (_) {
          return '';
        }
      },
    );
  }

  /// 刷新 announce pend 粗提示（出站 offered 数）。
  Future<void> refreshAnnouncePend() async {
    try {
      if (!_transferStackMounted && _offerAcceptService == null) {
        _announcePendCount = 0;
        return;
      }
      final tasks = await transferTaskStore();
      _announcePendCount = await tasks.countOutboundOffered();
    } catch (_) {}
  }

  /// FGS TaskHandler 注入：enroll 落库后向 UI 发 pairing_settled（仅 FGS isolate）。
  Future<void> Function(Peer peer)? onFgsPairingSettled;

  /// 配对成功收尾：刷新列表、组播宣告（在线靠 UDP announce）。
  Future<void> onPairingSettled(Peer peer) async {
    await refreshPairedPeers();
    await peerRegistry().reloadPaired();
    unawaited(ensureTransferStack());
    discoveryService().announceNow();
    peerApiClient().invalidate(peer.fingerprint);
    final notifyUi = onFgsPairingSettled;
    if (notifyUi != null) {
      unawaited(notifyUi(peer));
    }
  }

  /// 网卡/地址变化：持有发现则 **强制冷启**（T2）；UI+FGS 时转发。
  Future<DiscoveryEnsureResult> healDiscoveryAfterNetworkChange() =>
      forceDiscoveryColdStart(reason: 'network_or_address');

  /// T1：网络丢失 → 只 stop，不 join。
  Future<void> stopDiscoveryForNetworkLoss() async {
    await stopDiscovery();
    _armRxWatchdog();
  }

  /// 强制 UDP 冷启（T2 / 兜底 / 显式请求）。
  ///
  /// [throttled]：回前台 T4，距上次成功 JOIN &lt; 45s 则只 announce。
  Future<DiscoveryEnsureResult> forceDiscoveryColdStart({
    required String reason,
    bool throttled = false,
  }) async {
    AppLogger.log(
      'discovery cold start',
      scope: 'discovery',
      details: {
        'reason': reason,
        'throttled': throttled,
        'host': hostAddress,
      },
    );

    if (throttled && _lastDiscoveryJoinAt != null) {
      final elapsed = DateTime.now().difference(_lastDiscoveryJoinAt!);
      if (elapsed < _resumeColdStartMin) {
        AppLogger.log(
          'discovery cold start throttled → announce only',
          scope: 'discovery',
          details: {
            'reason': reason,
            'elapsedSec': elapsed.inSeconds,
          },
        );
        discoveryService().announceNow();
        return const DiscoveryEnsureResult(DiscoveryEnsureStatus.ready);
      }
    }

    await refreshLocalAddress();
    final addr = hostAddress;
    if (addr.isEmpty || addr == '0.0.0.0') {
      AppLogger.log(
        'discovery cold start no network',
        scope: 'discovery',
        details: {'reason': reason, 'host': addr},
      );
      await stopDiscovery();
      _armRxWatchdog();
      return const DiscoveryEnsureResult(DiscoveryEnsureStatus.noNetwork);
    }
    final result = await ensureDiscovery(rebuild: true);
    AppLogger.log(
      'discovery cold start done',
      scope: 'discovery',
      details: {
        'reason': reason,
        'ok': result.ok,
        'status': result.status.name,
        'host': hostAddress,
      },
    );
    if (result.ok) {
      _noteDiscoveryRebuilt(reason);
    } else {
      _armRxWatchdog();
    }
    return result;
  }

  /// 对离线已配对做 HTTPS ping 拉绿（无离线则跳过）。
  Future<void> probeOfflinePairedPeers() async {
    await refreshPairedPeers();
    final onlineFps =
        peerRegistry().onlinePaired.map((p) => p.fingerprint).toSet();
    final targets = pairedPeers.value.where((p) {
      if (onlineFps.contains(p.fingerprint)) return false;
      final dial = p.lastSeenAddress;
      return dial != null && PeerAddress.tryParse(dial) != null;
    }).toList();
    if (targets.isEmpty) {
      AppLogger.logVerbose(
        'probe offline paired: none',
        scope: 'presence',
      );
      return;
    }
    AppLogger.log(
      'probe offline paired',
      scope: 'presence',
      details: {
        'count': targets.length,
        'fps': [
          for (final p in targets.take(8))
            p.fingerprint.length > 12
                ? '${p.fingerprint.substring(0, 12)}…'
                : p.fingerprint,
        ],
      },
    );
    for (var i = 0; i < targets.length; i += _offlineProbeMaxConcurrent) {
      final batch = targets.skip(i).take(_offlineProbeMaxConcurrent);
      await Future.wait(batch.map(_pingPairedPeerForGreen));
    }
  }

  Future<bool> _pingPairedPeerForGreen(Peer peer) async {
    final short = peer.fingerprint.length > 12
        ? '${peer.fingerprint.substring(0, 12)}…'
        : peer.fingerprint;
    try {
      final response = await peerApiClient().get(
        peer.fingerprint,
        PingEndpoint.path,
        connectTimeout: presencePingGateTimeout,
        receiveTimeout: presencePingGateTimeout,
      );
      final ok = response != null && response.statusCode == 200;
      AppLogger.log(
        ok ? 'offline probe ping ok' : 'offline probe ping fail',
        scope: 'presence',
        details: {
          'fp': short,
          'dial': peer.lastSeenAddress,
          'status': response?.statusCode,
        },
      );
      if (!ok) return false;
      final dial = peer.lastSeenAddress!;
      peerRegistry().markReachable(
        fingerprint: peer.fingerprint,
        name: peer.name,
        brand: peer.brand,
        model: peer.model,
        emoji: peer.emoji,
        address: dial,
      );
      return true;
    } catch (e) {
      AppLogger.log(
        'offline probe ping threw',
        scope: 'presence',
        error: e,
        details: {'fp': short, 'dial': peer.lastSeenAddress},
      );
      return false;
    }
  }

  void _noteDiscoveryRebuilt(String _) {
    _lastDiscoveryJoinAt = DateTime.now();
    _armRxWatchdog();
  }

  void _noteForeignDiscoveryRx() {
    _armRxWatchdog();
  }

  void _armRxWatchdog() {
    _rxWatchdog?.cancel();
    _rxWatchdog = Timer(_rxWatchdogPeriod, () {
      AppLogger.log(
        'UDP RX watchdog fired (15m no foreign announce)',
        scope: 'discovery',
        details: {
          'healthy': discoveryService().isHealthy,
          'host': hostAddress,
        },
      );
      unawaited(
        forceDiscoveryColdStart(reason: 'rx_watchdog_15m'),
      );
    });
  }

  void _ensureDiscoveryNetworkGuard() {
    if (_discoveryNetGuardStarted) return;
    _discoveryNetGuardStarted = true;
    _armRxWatchdog();
    unawaited(_discoveryNetSub?.cancel() ?? Future.value());
    _discoveryNetSub = Connectivity().onConnectivityChanged.listen((results) {
      _onDiscoveryConnectivity(results);
    });
    unawaited(
      Connectivity().checkConnectivity().then(_onDiscoveryConnectivity),
    );
  }

  void _onDiscoveryConnectivity(List<ConnectivityResult> results) {
    final lan = results.any(
      (r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.other,
    );
    if (_hadLanConnectivity != lan) {
      AppLogger.log(
        'discovery connectivity',
        scope: 'discovery',
        details: {
          'lan': lan,
          'wasLan': _hadLanConnectivity,
          'results': [for (final r in results) r.name],
          'host': hostAddress,
        },
      );
    }
    if (_hadLanConnectivity && !lan) {
      _discoveryNetDebounce?.cancel();
      unawaited(stopDiscoveryForNetworkLoss());
    } else if (!_hadLanConnectivity && lan) {
      _discoveryNetDebounce?.cancel();
      _discoveryNetDebounce = Timer(_discoveryNetDebounceDelay, () {
        unawaited(
          forceDiscoveryColdStart(reason: 'connectivity_restored'),
        );
      });
    }
    _hadLanConnectivity = lan;
  }

  /// 主动组播。
  Future<void> announceNowRouted() async {
    discoveryService().announceNow();
  }

  /// 解除配对：删 peers 行 + 清拨号缓存 + 离线视图。
  Future<void> revokePeer(String fingerprint) async {
    final repo = await peerRepository();
    await repo.revoke(fingerprint);
    peerRuntimeStore().clear(fingerprint);
    await refreshPairedPeers();
    await peerRegistry().reloadPaired();
    peerRegistry().markUnreachable(fingerprint);
    peerApiClient().invalidate(fingerprint);
  }

  DiscoveryForegroundGuard _discoveryForegroundGuard() {
    return _discoveryGuard ??= DiscoveryForegroundGuard(
      stop: () => discoveryService().stop(),
      start: () => discoveryService().start(),
      networkReady: () async {
        if (hostAddress == '0.0.0.0') {
          await refreshLocalAddress();
        }
        return hostAddress != '0.0.0.0';
      },
    );
  }

  Future<void> _bindDiscoveryListeners() async {
    if (_discoveryBindingsReady) return;
    var identity = await deviceIdentityService.identity;
    for (var i = 0;
        i < 3 && identity.fingerprint == 'unavailable';
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      identity = await deviceIdentityService.identity;
    }
    final registry = peerRegistry();
    final discovery = discoveryService();
    _announceSubscription?.cancel();
    _announceSubscription = discovery.announceStream.listen((payload) {
      _noteForeignDiscoveryRx();
      registry.onAnnounce(payload);
      unawaited(_syncPairedAddress(payload));
      if (payload.brand.trim().isNotEmpty ||
          payload.emoji.trim().isNotEmpty) {
        unawaited(_fillPairedStaticFromAnnounce(payload));
      }
    });
    _sweepTimer?.cancel();
    _sweepTimer = Timer.periodic(presenceSweepInterval, (_) {
      unawaited(
        registry.sweepExpired(
          verifyPairedReachable: _verifyPairedReachableForPresence,
        ),
      );
    });
    _discoveryBindingsReady = true;
    _ensureDiscoveryNetworkGuard();
  }

  /// 方案 A：UDP 超时后短 ping；拨号前对齐 announce 地址到 peers 表。
  Future<bool> _verifyPairedReachableForPresence(OnlinePeer peer) async {
    final short = peer.fingerprint.length > 12
        ? '${peer.fingerprint.substring(0, 12)}…'
        : peer.fingerprint;
    try {
      final addr = PeerAddress.tryParse(peer.address)?.formatted;
      if (addr == null) {
        AppLogger.log(
          'presence HTTPS ping skip: bad address',
          scope: 'presence',
          details: {'fp': short, 'address': peer.address},
        );
        return false;
      }
      final repo = await peerRepository();
      final existing = await repo.findByFingerprint(peer.fingerprint);
      if (existing == null) return false;
      if (existing.lastSeenAddress != addr) {
        AppLogger.log(
          'presence sync dial address',
          scope: 'presence',
          details: {
            'fp': short,
            'from': existing.lastSeenAddress,
            'to': addr,
          },
        );
        await repo.updateLastSeenAddress(peer.fingerprint, addr);
        await refreshPairedPeers();
        peerApiClient().invalidate(peer.fingerprint);
      }
      final response = await peerApiClient().get(
        peer.fingerprint,
        PingEndpoint.path,
        connectTimeout: presencePingGateTimeout,
        receiveTimeout: presencePingGateTimeout,
      );
      final ok = response != null && response.statusCode == 200;
      if (ok) {
        AppLogger.logVerbose(
          'presence HTTPS ping ok',
          scope: 'presence',
          details: {
            'fp': short,
            'dial': addr,
            'status': response!.statusCode,
          },
        );
      } else {
        AppLogger.log(
          'presence HTTPS ping fail',
          scope: 'presence',
          details: {
            'fp': short,
            'dial': addr,
            'status': response?.statusCode,
          },
        );
      }
      return ok;
    } catch (e) {
      AppLogger.log(
        'presence HTTPS ping threw',
        scope: 'presence',
        error: e,
        details: {'fp': short, 'address': peer.address},
      );
      return false;
    }
  }

  /// 前台保证组播：一层 stop+start，网未好/join 失败最多 3 次。
  Future<DiscoveryEnsureResult> ensureDiscovery({
    required bool rebuild,
  }) async {
    await _bindDiscoveryListeners();
    if (hostAddress == '0.0.0.0') {
      await refreshLocalAddress();
      _addressFuture = Future.value(hostAddress);
    }
    final result = await _discoveryForegroundGuard().ensure(rebuild: rebuild);

    if (result.ok) {
      discoveryService().announceNow();
    }
    return result;
  }

  /// 冷启动入口（与 [ensureDiscovery] 相同）。
  Future<DiscoveryEnsureResult> startDiscovery() =>
      ensureDiscovery(rebuild: false);

  void onAppPaused() {
    _discoveryFailurePrompted = false;
  }

  /// 回到前台：T4 节流冷启 + 离线已配对 ping 拉绿。
  Future<DiscoveryEnsureResult> onAppResumed() async {
    // 反影子：若进程曾被杀，running 降为 paused，不自动弹窗续传。
    unawaited(backupEngine().bootstrap());
    unawaited(categoryDownloadEngine().bootstrap());
    unawaited(probeOfflinePairedPeers());
    final result = await forceDiscoveryColdStart(
      reason: 'app_resumed',
      throttled: true,
    );
    _publishDiscoveryResult(result);
    return result;
  }

  void _publishDiscoveryResult(DiscoveryEnsureResult result) {
    if (result.ok) {
      discoveryAlert.value = null;
      return;
    }
    discoveryAlert.value = result;
  }

  bool get discoveryFailurePrompted => _discoveryFailurePrompted;

  void markDiscoveryFailurePrompted() {
    _discoveryFailurePrompted = true;
  }

  /// 弹窗「再试」：允许本周期再提示一次，并再走一层重建。
  Future<DiscoveryEnsureResult> retryDiscoveryAfterPrompt() async {
    _discoveryFailurePrompted = false;
    discoveryAlert.value = null;
    final result = await ensureDiscovery(rebuild: true);
    _publishDiscoveryResult(result);
    return result;
  }

  /// 已配对设备 announce 到达时补全 brand / emoji（持久 Static）。
  Future<void> _fillPairedStaticFromAnnounce(AnnouncePayload payload) async {
    try {
      final repo = await peerRepository();
      var changed = false;
      if (payload.brand.trim().isNotEmpty) {
        changed = await repo.fillBrandIfEmpty(
              payload.fingerprint,
              payload.brand,
            ) ||
            changed;
      }
      if (payload.emoji.trim().isNotEmpty) {
        changed = await repo.updateEmoji(
              payload.fingerprint,
              payload.emoji,
            ) ||
            changed;
      }
      if (changed) await refreshPairedPeers();
    } catch (_) {}
  }

  /// 本机显示名 / emoji 变更后：冷总线 + announce，并向已连对端再推 WS static。
  Future<void> publishLocalIdentityDisplay() async {
    await _commitSharedReplica('identity_display');
    try {
      await announceNowRouted();
    } catch (_) {}
    try {
      await peerStatusService().republishStaticToConnected();
    } catch (_) {}
  }

  Future<void> _syncPairedAddress(AnnouncePayload payload) async {
    try {
      final repo = await peerRepository();
      final existing = await repo.findByFingerprint(payload.fingerprint);
      if (existing == null) return;
      final address = PeerAddress.format(payload.host, payload.port);
      if (address == null) return;
      if (existing.lastSeenAddress == address) return;

      await repo.updateLastSeenAddress(payload.fingerprint, address);
      await refreshPairedPeers();
      peerApiClient().invalidate(payload.fingerprint);
    } catch (_) {}
  }

  /// 停止发现（测试/宿主重建用）。
  Future<void> stopDiscovery() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    await _announceSubscription?.cancel();
    _announceSubscription = null;
    _discoveryBindingsReady = false;
    await _discoveryService?.stop();
  }
}

final serviceLocator = ServiceLocator();
