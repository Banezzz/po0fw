/*
 * po0 防火墙自动加白
 * 兼容：Surge / Stash / Shadowrocket / Loon / Quantumult X
 * （Egern 运行模型不同，用独立的 egern/po0-firewall-whitelist.js）
 *
 * POST /api/firewall/<token>/add  把"当前请求源 IP"加入白名单，并回显
 *   {enabled, whitelist:[{ip,slot}], limit, currentIp}。token 走 URL 路径，无需
 *   Authorization 头。服务端对已在白名单的 IP 做幂等处理（重复请求不
 *   重复占坑、不推进淘汰队列），因此这里每次直接无脑请求。
 * 加白粒度为 C 段（/24）：服务端把 whitelist 条目和 currentIp 都归一化成
 *   x.x.x.0/24 回显；同段内换 IP 不产生新写入。脚本用 sameC24() 做匹配，
 *   兼容精确 IP 与 /24 段混杂的新旧格式。
 * 白名单写满后按写入时间先进先出自动淘汰最旧 IP；API 无删除接口。
 *
 * 策略：
 * - 每次直接 POST 上报当前出口 IP，蜂窝与 WiFi/有线同等处理。
 * - 默认 slotless 写入：按 updated_at 触发 LRU 淘汰，被挤出的设备靠自己的
 *   cron/事件几分钟内自动补回。
 * - 可选固定槽位：token 后加 @N（如 pgnfw_xxx@0）→ POST .../add?slot=N，
 *   把本机 IP 钉在槽位 N，**永不被 LRU 淘汰**。槽位写入语义：
 *     · 本机 IP 已在该槽位 → 刷新 updated_at；
 *     · 槽位有旧 IP → 行级顶替，旧 IP 丢弃；
 *     · 本机 IP 已 slotless → 删 slotless 行升级到该槽位；
 *     · 本机 IP 已占用**别的**槽位 → 403 冲突，需先去 UI 删旧槽位（脚本会报 ❌）。
 * - 蜂窝（主接口 pdp_ip*）写入的 IP 仅做 📶 标记，便于面板识别。
 *
 * 健壮性（针对 network-changed 场景，切网瞬间隧道会重建并掐断在途连接）：
 * - 每次请求都带 JS 层硬超时，客户端回调不来时也能自行了结；
 * - 传输失败按退避重试，第一发被切网掐断后仍有机会补上；
 * - 每个 token 独立成败，一个卡住不影响另一个的结果上报；
 * - 全链路兜底 catch + watchdog，保证任何路径下都会调用 $done，
 *   绝不静默吊死到被客户端 timeout 杀掉（那样没有任何提示，最难排查）。
 *
 * token 来源（优先级从高到低）：
 * 1. argument: tokens=<pgnfw_xxx>[@槽位],<pgnfw_yyy>（Surge/Loon/Stash 模块参数）
 * 2. 持久化存储 key "po0fw_tokens"（Quantumult X 等不支持参数的客户端，
 *    可用 BoxJs 或一次性脚本写入）
 * 3. 下面的 INLINE_TOKENS 常量（自己维护脚本副本时直接填这里）
 */

var INLINE_TOKENS = "";

var API_BASE = "https://124.221.69.228/api/firewall/"; // + <token> + "/add"
var STORE_PREFIX = "po0_fw_";
var TOKENS_KEY = "po0fw_tokens";
var HIST_WINDOW_MS = 24 * 3600 * 1000; // 📶 标记的记账窗口

// 时序预算，需装进载体里的 timeout=60：
// 稳定等待 2s + 3 次尝试 × 12s + 退避 2s、4s = 最坏 44s，watchdog 50s 收尾。
// 调大任何一项时记得同步检查这个总和仍小于 WATCHDOG_MS。
var SETTLE_DELAY_MS = 2000; // 事件触发后先让接口稳定，避免第一发就撞上隧道重建
var REQ_TIMEOUT_MS = 12000; // 单次请求的 JS 层硬超时
var MAX_ATTEMPTS = 3; // 含首次，传输失败最多试这么多次
var RETRY_BASE_MS = 2000; // 第 n 次失败后等 n × 该值
var WATCHDOG_MS = 50000; // 最后兜底，必须小于载体的 timeout

/* ---------- 环境兼容层 ---------- */

var isQX = typeof $task !== "undefined";
var isSurgeLike = typeof $httpClient !== "undefined"; // Surge/Stash/Shadowrocket/Loon
var hasTimer = typeof setTimeout === "function";

function storeRead(key) {
  try {
    if (isQX) return $prefs.valueForKey(key);
    if (typeof $persistentStore !== "undefined") return $persistentStore.read(key);
  } catch (e) {}
  return null;
}

function storeWrite(value, key) {
  try {
    if (isQX) return $prefs.setValueForKey(value, key);
    if (typeof $persistentStore !== "undefined") return $persistentStore.write(value, key);
  } catch (e) {}
  return false;
}

function notify(title, subtitle, body) {
  try {
    if (isQX) $notify(title, subtitle, body);
    else if (typeof $notification !== "undefined") $notification.post(title, subtitle, body);
  } catch (e) {}
}

function delay(ms) {
  return new Promise(function (resolve) {
    if (hasTimer && ms > 0) setTimeout(resolve, ms);
    else resolve();
  });
}

// 单次请求：客户端回调与 JS 层硬超时双保险，且保证只 settle 一次。
// 永远 resolve、从不 reject——失败信息放在 .error 里，让调用方自己决定重试。
function httpRequest(method, opts) {
  return new Promise(function (resolve) {
    var settled = false;
    var timer = null;

    function done(r) {
      if (settled) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      resolve(r);
    }

    // 切网时客户端会重建隧道并掐断在途连接，此时部分客户端不回调 error。
    // 没有这道兜底，整条 Promise 链就永不 settle，脚本静默吊死到被杀。
    if (hasTimer) {
      timer = setTimeout(function () {
        done({ error: "请求超时（" + Math.round(REQ_TIMEOUT_MS / 1000) + "s 无响应）" });
      }, REQ_TIMEOUT_MS);
    }

    try {
      if (isQX) {
        opts.method = method;
        $task.fetch(opts).then(
          function (resp) {
            done({ body: resp.body, status: resp.statusCode });
          },
          function (err) {
            done({ error: String((err && err.error) || err) });
          }
        );
      } else if (isSurgeLike) {
        var cb = function (error, response, body) {
          if (error) done({ error: String(error) });
          else done({ body: body, status: response && (response.status || response.statusCode) });
        };
        // 必须带着 $httpClient 一起调用。摘成裸函数（var fn = $httpClient.post; fn(...)）
        // 会丢掉 this 绑定，在 Shadowrocket 的 JSCore 桥接下抛异常或静默不发请求。
        if (method === "POST") $httpClient.post(opts, cb);
        else $httpClient.get(opts, cb);
      } else {
        done({ error: "unsupported client" });
      }
    } catch (e) {
      done({ error: "请求异常: " + String((e && e.message) || e) });
    }
  });
}

function getArgumentTokens() {
  if (typeof $argument === "undefined" || $argument === null) return "";
  // Loon 插件 argument=[{tokens}] 会注入对象形态
  if (typeof $argument === "object") return String($argument.tokens || "");
  if (typeof $argument === "string" && $argument.length > 0) {
    // Shadowrocket 等客户端可能把配置里的外层引号原样传入，先剥掉
    if (/^["'].*["']$/.test($argument)) $argument = $argument.slice(1, -1);
    // Loon 也可能注入 JSON 字符串
    if ($argument.charAt(0) === "{") {
      try {
        return String(JSON.parse($argument).tokens || "");
      } catch (e) {}
    }
    // Surge/Stash 风格 tokens=xxx&...
    var pairs = $argument.split("&");
    for (var i = 0; i < pairs.length; i++) {
      var idx = pairs[i].indexOf("=");
      if (idx > 0 && pairs[i].slice(0, idx) === "tokens") {
        var raw = pairs[i].slice(idx + 1);
        try {
          return decodeURIComponent(raw);
        } catch (e) {
          return raw; // 含裸 % 等非法转义时按原样用，别让整个脚本挂掉
        }
      }
    }
    // 直接把整串当 token 填的兜底（如 Loon argument="pgnfw_..."）
    if ($argument.indexOf("pgnfw_") === 0) return $argument;
  }
  return "";
}

function onCellular() {
  try {
    var iface =
      ($network.v4 && $network.v4.primaryInterface) ||
      ($network.v6 && $network.v6.primaryInterface) ||
      "";
    return iface.indexOf("pdp_ip") === 0;
  } catch (e) {
    return false; // 客户端不支持 $network 时按非蜂窝处理
  }
}

// 幂等：watchdog 与正常结束可能都会走到这里，只认第一次。
var finished = false;

function finish(title, content, allOk) {
  if (finished) return;
  finished = true;
  try {
    if (isQX) {
      $done();
      return;
    }
    $done({
      title: title,
      content: content,
      icon: allOk ? "checkmark.shield" : "exclamationmark.shield",
      "icon-color": allOk ? "#34C759" : "#FF3B30",
    });
  } catch (e) {
    // 面板形态不被支持时退回无参 $done，至少让客户端知道脚本结束了
    try {
      $done();
    } catch (e2) {}
  }
}

/* ---------- 业务逻辑 ---------- */

// 服务端按 C 段（/24）加白，条目可能是精确 IP 或 x.x.x.0/24。
// 任一侧为 /24 段时按前三段比较，两侧均为精确 IP 时要求全等。
function sameC24(a, b) {
  if (!a || !b) return false;
  a = String(a);
  b = String(b);
  if (a === b) return true;
  if (a.slice(-3) !== "/24" && b.slice(-3) !== "/24") return false;
  var pa = a.replace("/24", "").split(".");
  var pb = b.replace("/24", "").split(".");
  return (
    pa.length === 4 && pb.length === 4 && pa[0] === pb[0] && pa[1] === pb[1] && pa[2] === pb[2]
  );
}

function readHistory(key) {
  try {
    var h = JSON.parse(storeRead(key) || "[]");
    if (!Array.isArray(h)) return [];
    var cutoff = Date.now() - HIST_WINDOW_MS;
    return h.filter(function (e) {
      return e && e.ts > cutoff;
    });
  } catch (e) {
    return [];
  }
}

function apiCall(token, slot) {
  // token 走 URL 路径，命中 /add 即把当前出口 IP 加白；带 slot 则钉固定槽位
  var url = API_BASE + encodeURIComponent(token) + "/add";
  if (slot !== null && slot !== undefined && slot !== "") {
    url += "?slot=" + encodeURIComponent(slot);
  }
  return httpRequest("POST", {
    url: url,
    headers: { "Content-Type": "application/json" },
    body: "",
    timeout: 10, // 认这个字段的客户端会先于 JS 层超时给出错误
  }).then(function (r) {
    if (r.error) return { error: r.error };
    var data = null;
    try {
      data = JSON.parse(r.body);
    } catch (e) {}
    // 带槽位写入且本机 IP 已占用别的槽位 → 服务端 403 冲突，需去 UI 删旧槽位
    if (r.status === 403) {
      return {
        error: "槽位冲突：本机 IP 已在其它槽位，请先去 UI 删除",
        conflict: true,
        currentIp: data && data.currentIp,
      };
    }
    if (!data) return { error: "响应异常: " + String(r.body).slice(0, 80) };
    // whitelist 元素为 {ip, slot} 对象（旧版曾是纯 IP 字符串）：记下 ip→slot 再摊平成 IP 数组
    var raw = Array.isArray(data.whitelist) ? data.whitelist : [];
    data.slotOf = {};
    raw.forEach(function (e) {
      if (e && typeof e === "object" && e.slot !== null && e.slot !== undefined) {
        data.slotOf[e.ip] = e.slot;
      }
    });
    data.whitelist = raw.map(function (e) {
      return e && typeof e === "object" ? e.ip : e;
    });
    data.applied =
      data.enabled === true &&
      data.whitelist.some(function (ip) {
        return sameC24(ip, data.currentIp);
      });
    return data;
  });
}

// 只对传输层失败重试：切网瞬间第一发常被隧道重建掐断，退避后往往就落在
// 已经稳定的接口上。服务端给出的明确答复（含 403 槽位冲突）重试没有意义。
function apiCallWithRetry(token, slot, attempt) {
  return apiCall(token, slot).then(function (r) {
    if (!r.error || r.conflict || attempt >= MAX_ATTEMPTS) return r;
    return delay(RETRY_BASE_MS * attempt).then(function () {
      return apiCallWithRetry(token, slot, attempt + 1);
    });
  });
}

function ensureWhitelisted(item, index) {
  var kvState = STORE_PREFIX + index;
  var kvHist = STORE_PREFIX + "hist_" + index;
  var cellular = onCellular();
  var ctx = { kvState: kvState, kvHist: kvHist, slot: item.slot };

  // 服务端对重复 IP 幂等，直接请求 /add 即可，无需先查
  return apiCallWithRetry(item.token, item.slot, 1).then(function (st) {
    if (st.applied) {
      var hist = readHistory(kvHist);
      var last = hist.length ? hist[hist.length - 1] : null;
      if (!last || last.ip !== st.currentIp) {
        hist.push({ ip: st.currentIp, src: cellular ? "cell" : "fixed", ts: Date.now() });
        storeWrite(JSON.stringify(hist.slice(-10)), kvHist);
      }
    }
    ctx.st = st;
    return ctx;
  });
}

// 每个 token 独立成败：一个 token 抛异常不该拖垮其它 token 的结果上报。
function safeEnsure(item, index) {
  try {
    return ensureWhitelisted(item, index).catch(function (e) {
      return {
        kvState: STORE_PREFIX + index,
        kvHist: STORE_PREFIX + "hist_" + index,
        slot: item.slot,
        st: { error: "脚本异常: " + String((e && e.message) || e) },
      };
    });
  } catch (e) {
    return Promise.resolve({
      kvState: STORE_PREFIX + index,
      kvHist: STORE_PREFIX + "hist_" + index,
      slot: item.slot,
      st: { error: "脚本异常: " + String((e && e.message) || e) },
    });
  }
}

// 每 token 一行：不含 token，只含白名单/坑位信息；蜂窝加的 IP 标 📶
function describe(index, ctx) {
  var st = ctx.st;
  var pin = ctx.slot !== null && ctx.slot !== undefined && ctx.slot !== "" ? " 📌" + ctx.slot : "";
  var head = "#" + (index + 1) + pin + " ";
  if (st.error) return head + "❌ " + st.error;
  if (st.enabled === false) return head + "⚠️ 防火墙未启用";
  var count = (st.whitelist && st.whitelist.length) || 0;
  if (!st.applied) return head + "❌ 加白未生效 " + count + "/" + st.limit;

  var hist = readHistory(ctx.kvHist);
  var cellIps = {};
  hist.forEach(function (e) {
    if (e.src === "cell") cellIps[e.ip] = true;
  });
  var slotOf = st.slotOf || {};
  var ips = st.whitelist
    .map(function (ip) {
      var slotTag = slotOf[ip] !== undefined ? " 📌" + slotOf[ip] : "";
      return ip + slotTag + (cellIps[ip] ? " 📶" : "") + (sameC24(ip, st.currentIp) ? " ←" : "");
    })
    .join("\n    ");
  return head + "✅ " + count + "/" + st.limit + "\n    " + ips;
}

function report(results) {
  var okCount = 0;
  var exitIp = "?";
  var lines = [];
  var changed = false;

  for (var i = 0; i < results.length; i++) {
    var st = results[i].st;
    if (st.applied) okCount++;
    if (st.currentIp) exitIp = st.currentIp;
    lines.push(describe(i, results[i]));

    var state = (st.currentIp || "?") + "|" + (st.applied ? "1" : "0");
    if (storeRead(results[i].kvState) !== state) {
      storeWrite(state, results[i].kvState);
      changed = true;
    }
  }

  var allOk = okCount === results.length;
  var title =
    "po0 加白 " + okCount + "/" + results.length + " · 出口 " + exitIp + (onCellular() ? " 📶" : "");
  var content = lines.join("\n");

  // 仅在出口 IP 或加白状态较上次变化时通知，例行 POST 保持安静
  if (changed) {
    notify("po0 防火墙加白", title, content);
  }
  finish(title, content, allOk);
}

// 分隔符兼容 , | ; 、；非 pgnfw_ 开头的段（如未修改的占位提示）直接忽略。
// 每段可带可选 @槽位 后缀：pgnfw_xxx@0 → 钉槽位 0；无后缀则 slotless。
var tokens = (getArgumentTokens() || storeRead(TOKENS_KEY) || INLINE_TOKENS || "")
  .split(/[,|;、\s]+/)
  .map(function (s) {
    return s.trim();
  })
  .filter(function (s) {
    return s.indexOf("pgnfw_") === 0;
  })
  .map(function (s) {
    var at = s.indexOf("@");
    if (at === -1) return { token: s, slot: null };
    var n = parseInt(s.slice(at + 1), 10);
    return { token: s.slice(0, at), slot: isNaN(n) ? null : n };
  });

if (tokens.length === 0) {
  notify(
    "po0 防火墙加白",
    "未配置 token",
    "模块参数 tokens / 存储 key po0fw_tokens / 脚本内 INLINE_TOKENS 三选一填入 pgnfw_ token"
  );
  finish("po0 加白：未配置 token", "请填入 pgnfw_ token，多个用 | 分割", false);
} else {
  // 最后一道防线：上面任何一环出意外时，也要赶在客户端 timeout 杀进程之前
  // 给出可见结果，而不是让用户面对"什么都没发生"。
  if (hasTimer) {
    setTimeout(function () {
      finish(
        "po0 加白：整体超时",
        "已等待 " + Math.round(WATCHDOG_MS / 1000) + "s 仍无结果，本轮放弃",
        false
      );
    }, WATCHDOG_MS);
  }

  delay(SETTLE_DELAY_MS)
    .then(function () {
      return Promise.all(
        tokens.map(function (t, i) {
          return safeEnsure(t, i);
        })
      );
    })
    .then(report)
    .catch(function (e) {
      finish("po0 加白：运行异常", String((e && e.message) || e), false);
    });
}
