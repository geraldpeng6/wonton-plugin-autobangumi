# shellcheck shell=bash
# scripts/smoke.sh 与 e2e/smoke.sh 共用的插件探针。
# 钩子可用面（负责人 2026-11-07 定）：变量 SMOKE_STATE（数据标记，e2e 是文件、dev.sh probes 是目录）、
# SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、SMOKE_INSTANCE；助手 web_get、dweb。
# AutoBangumi：sso=none + 应用自带登录。上游在首次启动固定建出厂账号 admin/adminadmin
# （源码 module/database/user.py，应用没有改初始密码的配置项），插件 about 已写明首登改密。
# identity_check 用出厂账号走应用自己的登录，断言应用认出的当前用户；数据断言交给 data_write / data_check。
web_assert() { grep -q '<title>AutoBangumi'; }   # 标准输入：SPA 首页 HTML 的标题

ab_login() { # 出厂账号登录应用，会话 Cookie 落进 dweb 的会话 jar；成功回显应用响应
	dweb /api/v1/auth/login -X POST \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		--data 'username=admin&password=adminadmin'
}

identity_check() { # 应用自己的“当前用户”接口认出登录的账号
	local me
	ab_login >/dev/null || { echo "应用登录失败（出厂账号 admin）"; return 1; }
	me="$(web_get /api/v1/auth/me)" || { echo "读不到当前用户：$me"; return 1; }
	grep -q '"username":"admin"' <<<"$me" ||
		{ echo "应用认出的不是出厂管理员：$(head -c 200 <<<"$me")"; return 1; }
}

# ---------- 工具（MCP，规范 0.11 起清单声明）----------
MCP_TOOL="get_program_status"   # 只读：返回 {version, running, first_run}
MCP_ARGS="{}"
mcp_assert() { grep -q '"version"'; }   # 标准输入：工具调用结果

# ---------- 数据（重装/升级保数据）----------
# 数据标记：用出厂管理员建一个以标记为名的用户（应用 SQLite 在数据目录里，重装保留）。
ab_marker() { # 标记文件：SMOKE_STATE 是文件就用它，是目录就放里面
	if [[ -f "$SMOKE_STATE" ]]; then
		printf '%s' "$SMOKE_STATE"
	else
		printf '%s' "$SMOKE_STATE/marker"
	fi
}

ab_marker_read() { cat "$(ab_marker)" 2>/dev/null || true; }

ab_marker_write() { # <值>：原样覆盖写标记
	local f
	f="$(ab_marker)"
	mkdir -p "$(dirname "$f")"
	printf '%s' "$1" >"$f"
}

ab_users() { # 已登录会话：列出应用用户
	web_get /api/v1/users
}

data_write() { # 建一个用户名带随机标记的账号，作为重装后要找到的用户数据
	local marker resp
	marker="wonton$(date +%s)"
	ab_login >/dev/null || { echo "应用登录失败（出厂账号 admin）"; return 1; }
	resp="$(dweb /api/v1/users -X POST -H 'Content-Type: application/json' \
		--data "{\"username\":\"$marker\",\"password\":\"${marker}Pass1\"}")" ||
		{ echo "建用户失败：$resp"; return 1; }
	grep -q '"username"' <<<"$resp" || { echo "建用户的响应不对：$(head -c 200 <<<"$resp")"; return 1; }
	ab_marker_write "$marker"
}

data_check() { # 重装/升级后：标记用户还在应用的用户列表里
	local marker users
	marker="$(ab_marker_read)"
	[[ -n "$marker" ]] || { echo "没有数据标记（data_write 没跑？）"; return 1; }
	ab_login >/dev/null || { echo "应用登录失败（出厂账号 admin）"; return 1; }
	users="$(ab_users)" || { echo "读不到用户列表：$users"; return 1; }
	grep -q "\"$marker\"" <<<"$users" ||
		{ echo "标记用户 $marker 不在了，用户列表：$(head -c 300 <<<"$users")"; return 1; }
}
