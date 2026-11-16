// 会话级回滚策略（实现 6）：浏览器打开某站时，绑定层说了算。
// 整源下线就不嗅探；未知站（不在 10 源里）默认全开六路——通用嗅探器不挑站。

import 'source_registry.dart';

/// 该源当前能不能嗅探：没绑定（未知站）默认能；绑定了但整源下线就不能。
bool sniffEnabledFor(SourceBinding? binding) =>
    binding == null || binding.enabled;

/// 该源当前启用的适配器：没绑定默认全开六路；绑定了按 adapterPath + flags。
List<AdapterKind> activeAdaptersFor(SourceBinding? binding) {
  if (binding == null) {
    return List<AdapterKind>.unmodifiable(AdapterKind.values);
  }
  return binding.activeAdapters;
}
