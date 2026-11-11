-- Prebuilt PHP from dPanel's release repository (devetek/php-binary).
-- Each release is this plugin's own source build, made in CI for one Debian or
-- Ubuntu release and CPU, so a server downloads it instead of compiling.
local env = require("lib/env")
local process = require("lib/process")
local tools = require("lib/tools")

local M = {}

local shell_quote = tools.shell_quote
local join_path = tools.join_path

local function os_release()
    local content = tools.read_file("/etc/os-release") or ""
    local values = {}
    for key, value in content:gmatch("([%w_]+)=\"?([^\"\n]*)\"?") do
        values[key] = value
    end
    return values
end

local function arch_name()
    local arch = string.lower(RUNTIME.archType or "")
    if arch == "amd64" or arch == "x64" or arch == "x86_64" then
        return "amd64"
    end
    if arch == "arm64" or arch == "aarch64" then
        return "arm64"
    end
    return nil
end

--- The release asset for this server, or nil when no dPanel build fits it.
function M.asset_name(version)
    if RUNTIME.osType ~= "linux" then
        return nil
    end
    local release = os_release()
    local arch = arch_name()
    if (release.ID ~= "ubuntu" and release.ID ~= "debian") or not release.VERSION_ID or not arch then
        return nil
    end
    return "php-" .. version .. "-" .. release.ID .. "-" .. release.VERSION_ID .. "-" .. arch .. ".tar.xz"
end

--- Download information for PreInstall, or nil to build from source.
function M.release(version)
    if not env.DPANEL_PREBUILT then
        return nil
    end
    local asset = M.asset_name(version)
    if not asset then
        return nil
    end
    local url = env.DPANEL_RELEASES_URL .. "/php-" .. version .. "/" .. asset
    local http = require("http")
    local resp, err = http.get({ url = url .. ".sha256", headers = { ["User-Agent"] = "dpanel-mise-php" } })
    if err ~= nil or resp == nil or resp.status_code ~= 200 then
        return nil
    end
    local sha256 = (resp.body or ""):match("^(%x+)")
    if not sha256 or #sha256 ~= 64 then
        return nil
    end
    print("\27[96mNote:\27[0m Using the prebuilt PHP " .. version .. " from " .. url)
    return { version = version, url = url, sha256 = sha256 }
end

--- True when sdkPath holds an unpacked dPanel build.
function M.is_installed(sdkPath)
    return tools.file_exists(join_path(sdkPath, "build-info.json"))
end

local function build_prefix(sdkPath)
    local info = tools.read_file(join_path(sdkPath, "build-info.json")) or ""
    return info:match('"prefix"%s*:%s*"([^"]+)"')
end

--- Installs the OS packages the build links to, without any compiler.
function M.install(sdkPath, version)
    local list = join_path(sdkPath, "runtime-packages.txt")
    if not tools.file_exists(list) then
        error("The prebuilt PHP " .. version .. " has no runtime-packages.txt")
    end
    local missing = process.run(
        "while read -r p; do [ -z \"$p\" ] || dpkg-query -W -f='${db:Status-Abbrev}' \"$p\" 2>/dev/null | grep -q '^ii' || echo \"$p\"; done < " .. shell_quote(list),
        { quiet = "" }
    )
    local nothing_missing = missing.ok and (missing.output or ""):match("^%s*$") ~= nil
    if not env.SKIP_DEPS and not nothing_missing then
        print("Installing PHP runtime packages...")
        local sudo = ""
        local is_root = os.execute("[ \"$(id -u)\" = 0 ]")
        if is_root ~= true and is_root ~= 0 then
            sudo = "sudo -n "
        end
        local command = "export DEBIAN_FRONTEND=noninteractive; " ..
            sudo .. "apt-get update -qq && " ..
            "xargs -a " .. shell_quote(list) .. " " .. sudo ..
            "apt-get install -y -qq --no-install-recommends"
        local result = process.run(command, { quiet = "" })
        if not result.ok then
            error("\n\nFailed to install the runtime packages of the prebuilt PHP " .. version .. ".\n\n" ..
                tostring(result.output) .. "\n" ..
                "💡 Tip: \27[93mRun 'sudo -v' first, or install the packages in " .. list .. " yourself.\27[0m\n")
        end
    end

    -- PHP finds php.ini and its extensions by the path it was built for.
    -- Elsewhere, point it at this directory instead.
    local prefix = build_prefix(sdkPath)
    if prefix and prefix ~= sdkPath then
        local ext_dir = process.run(shell_quote(join_path(sdkPath, "bin", "php-config")) .. " --extension-dir", { quiet = "" })
        local relocated = (ext_dir.output or ""):gsub("%s+$", ""):gsub("^" .. prefix:gsub("%p", "%%%0"), sdkPath)
        tools.write_file(join_path(sdkPath, "conf.d", "00-dpanel-paths.ini"), "extension_dir = \"" .. relocated .. "\"\n")
    end

    local check = process.run(shell_quote(join_path(sdkPath, "bin", "php")) .. " -v", { quiet = "" })
    if not check.ok then
        error("\n\nThe prebuilt PHP " .. version .. " does not run on this server:\n" .. tostring(check.output) ..
            "\nSet PHP_DPANEL_PREBUILT=0 to build it from source instead.\n")
    end
    return { kind = "dpanel" }
end

--- Environment for a build used outside the path it was built for.
function M.env_keys(installDir)
    local prefix = build_prefix(installDir)
    if not prefix or prefix == installDir then
        return {}
    end
    return {
        { key = "PHPRC", value = installDir },
        { key = "PHP_INI_SCAN_DIR", value = join_path(installDir, "conf.d") },
    }
end

return M
