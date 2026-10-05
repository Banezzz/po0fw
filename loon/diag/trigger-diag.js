// Loon 触发器诊断脚本：只证明"Loon 派发了这次触发"。
// 弹一条通知、写一行日志、立刻结束。不碰网络，不读任何配置，不含 token。
var name = "?";
try {
  if (typeof $script !== "undefined" && $script && $script.name) name = String($script.name);
} catch (e) {}

var d = new Date();
function p(n) {
  return (n < 10 ? "0" : "") + n;
}
var t = p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());

console.log("[po0diag] fired " + name + " at " + t);
$notification.post("po0 触发诊断", name, "触发于 " + t);
$done();
