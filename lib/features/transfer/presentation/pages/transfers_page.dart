import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/task/transfer_task.dart';
import '../cubits/transfers_cubit.dart';

/// 传输任务列表（P2P + NAS）。
class TransfersPage extends StatelessWidget {
  const TransfersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => TransfersCubit()..start(),
      child: const _TransfersView(),
    );
  }
}

class _TransfersView extends StatelessWidget {
  const _TransfersView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('传输列表'),
        actions: [
          IconButton(
            tooltip: '清理已完成',
            onPressed: () => context.read<TransfersCubit>().clearDone(),
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => context.read<TransfersCubit>().refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: BlocBuilder<TransfersCubit, TransfersState>(
        builder: (context, state) {
          if (state.loading && state.tasks.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.error != null && state.tasks.isEmpty) {
            return Center(child: Text(state.error!));
          }
          if (state.tasks.isEmpty) {
            return const Center(child: Text('暂无传输任务'));
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: state.tasks.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final task = state.tasks[index];
              return _TaskTile(task: task);
            },
          );
        },
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = task.sizeBytes > 0
        ? (task.bytesTransferred / task.sizeBytes).clamp(0.0, 1.0)
        : null;
    return ListTile(
      leading: Icon(_iconFor(task.type), color: scheme.primary),
      title: Text(task.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_typeLabel(task.type)} · ${_stateLabel(task.state)}'),
          if (task.state == TransferTaskState.transferring) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 2),
            Text(
              progress == null
                  ? _sizeLabel(task.bytesTransferred)
                  : '${_sizeLabel(task.bytesTransferred)} / ${_sizeLabel(task.sizeBytes)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          if (task.state == TransferTaskState.failed &&
              (task.errorMessage?.isNotEmpty ?? false))
            Text(
              task.errorMessage!,
              maxLines: 2,
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
        ],
      ),
      isThreeLine: task.state == TransferTaskState.transferring ||
          task.state == TransferTaskState.failed,
    );
  }

  IconData _iconFor(TransferTaskType t) => switch (t) {
        TransferTaskType.nasDownload => Icons.download_outlined,
        TransferTaskType.nasUpload => Icons.upload_outlined,
        TransferTaskType.p2pOffer => Icons.send_outlined,
        TransferTaskType.p2pDownload => Icons.call_received_outlined,
      };

  String _typeLabel(TransferTaskType t) => switch (t) {
        TransferTaskType.nasDownload => 'NAS 下载',
        TransferTaskType.nasUpload => 'NAS 上传',
        TransferTaskType.p2pOffer => '互传发送',
        TransferTaskType.p2pDownload => '互传接收',
      };

  String _stateLabel(TransferTaskState s) => switch (s) {
        TransferTaskState.offered => '待确认',
        TransferTaskState.accepted => '已接受',
        TransferTaskState.transferring => '传输中',
        TransferTaskState.done => '完成',
        TransferTaskState.failed => '失败',
        TransferTaskState.cancelled => '已取消',
        TransferTaskState.expired => '已过期',
      };

  String _sizeLabel(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
