--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        env.lua
--

-- imports
import("core.base.option")
import("core.project.config")
import("private.action.require.impl.package")

-- get menu options
function menu_options()

    -- description
    local description = "Set environment and execute command, or print environment."

    -- menu options
    local options =
    {
        {'k', "kind",       "kv", nil, "Enable static/shared library.",
                                       values = {"static", "shared"}         },
        {'p', "plat",       "kv", nil, "Set the given platform."             },
        {'a', "arch",       "kv", nil, "Set the given architecture."         },
        {'m', "mode",       "kv", nil, "Set the given mode.",
                                       values = {"release", "debug"}         },
        {nil, "show",       "k",  nil, "Only show environment information."  },
        {'f', "configs",    "kv", nil, "Set the given extra package configs.",
                                       "e.g.",
                                       "    - xrepo env -f \"vs_runtime=MD\" zlib cmake ..",
                                       "    - xrepo env -f \"regex=true,thread=true\" \"zlib,boost\" cmake .."},
        {'b', "packages",   "kv", nil, "Set the packages to be bound",
                                       "e.g.",
                                       "    - xrepo env -b \"python 3.x\" python",
                                       "    - xrepo env -b \"llvm 11.x\" bash",
                                       "      $ clang --version",
                                       "    - xrepo env -p android -b \"zlib,luajit 2.x\" luajit xx.lua"},
        {},
        {nil, "program",    "v",  nil, "Set the program name to be run",
                                       "e.g.",
                                       "    - xrepo env",
                                       "    - xrepo env python",
                                       "    - xrepo env -p android luajit xx.lua"},
        {nil, "arguments",  "vs", nil, "Set the program arguments to be run"}
    }

    -- show menu options
    local function show_options()

        -- show usage
        cprint("${bright}Usage: $${clear cyan}xrepo env [options] [packages] [program] [arguments]")

        -- show description
        print("")
        print(description)

        -- show options
        option.show_options(options, "env")
    end
    return options, show_options, description
end

-- get requires
function _get_requires(packages)
    local requires = packages
    local requires_extra = {}
    local extra = {system = false}
    if option.get("mode") == "debug" then
        extra.debug = true
    end
    if option.get("kind") == "shared" then
        extra.configs = extra.configs or {}
        extra.configs.shared = true
    end
    local configs = option.get("configs")
    if configs then
        extra.system  = false
        extra.configs = extra.configs or {}
        local extra_configs, errors = ("{" .. configs .. "}"):deserialize()
        if extra_configs then
            table.join2(extra.configs, extra_configs)
        else
            raise(errors)
        end
    end
    for _, require_str in ipairs(requires) do
        requires_extra[require_str] = extra
    end
    return requires, requires_extra
end

-- enter project
function _enter_project()

    -- enter working project directory
    local workdir = path.join(os.tmpdir(), "xrepo", "working")
    if not os.isdir(workdir) then
        os.mkdir(workdir)
        os.cd(workdir)
        os.vrunv("xmake", {"create", "-P", "."})
    else
        os.cd(workdir)
    end

    -- do configure first
    local config_argv = {"f", "-c"}
    if option.get("verbose") then
        table.insert(config_argv, "-v")
    end
    if option.get("diagnosis") then
        table.insert(config_argv, "-D")
    end
    if option.get("plat") then
        table.insert(config_argv, "-p")
        table.insert(config_argv, option.get("plat"))
    end
    if option.get("arch") then
        table.insert(config_argv, "-a")
        table.insert(config_argv, option.get("arch"))
    end
    local mode  = option.get("mode")
    if mode then
        table.insert(config_argv, "-m")
        table.insert(config_argv, mode)
    end
    local kind  = option.get("kind")
    if kind then
        table.insert(config_argv, "-k")
        table.insert(config_argv, kind)
    end
    os.vrunv("xmake", config_argv)

    -- load config
    config.load()
end

-- add values to environment variable
function _package_addenv(envs, name, ...)
    local values = {...}
    if #values > 0 then
        local oldenv = envs[name]
        local appendenv = path.joinenv(values)
        if oldenv == "" or oldenv == nil then
            envs[name] = appendenv
        else
            envs[name] = appendenv .. path.envsep() .. oldenv
        end
    end
end

-- add package environments
function _package_addenvs(envs, instance)

    -- only for xmake::package
    if instance:isSys() then
        return
    end

    -- add run envs, e.g. PATH, LD_LIBRARY_PATH, ..
    local installdir = instance:installdir()
    for name, values in pairs(instance:envs()) do
        if name == "PATH" or name == "LD_LIBRARY_PATH" or name == "DYLD_LIBRARY_PATH" then
            for _, value in ipairs(values) do
                if path.is_absolute(value) then
                    _package_addenv(envs, name, value)
                else
                    _package_addenv(envs, name, path.join(installdir, value))
                end
            end
        else
            _package_addenv(envs, name, unpack(table.wrap(values)))
        end
    end

    -- add library envs, e.g. ACLOCAL_PATH, PKG_CONFIG_PATH ..
    if instance:is_library() then
        local pkgconfig = path.join(installdir, "lib", "pkgconfig")
        if os.isdir(pkgconfig) then
            _package_addenv(envs, "PKG_CONFIG_PATH", pkgconfig)
        end
        pkgconfig = path.join(installdir, "share", "pkgconfig")
        if os.isdir(pkgconfig) then
            _package_addenv(envs, "PKG_CONFIG_PATH", pkgconfig)
        end
        local aclocal = path.join(installdir, "share", "aclocal")
        if os.isdir(aclocal) then
            _package_addenv(envs, "ACLOCAL_PATH", aclocal)
        end
        _package_addenv(envs, "CMAKE_PREFIX_PATH", installdir)
    end
end

-- get package environments
function _package_getenvs()
    local envs = os.getenvs()
    local packages = option.get("packages") or option.get("program")
    if packages then
        _enter_project()
        packages = packages:split(',', {plain = true})
        local requires, requires_extra = _get_requires(packages)
        for _, instance in ipairs(package.load_packages(requires, {requires_extra = requires_extra})) do
            _package_addenvs(envs, instance)
        end
    end
    return envs
end

-- main entry
function main()
    local envs = _package_getenvs()
    local program = option.get("program")
    if program and not option.get("show") then
        if envs and envs.PATH then
            os.setenv("PATH", envs.PATH)
        end
        os.execv(program, option.get("arguments"), {envs = envs})
    else
        print(envs)
    end
end
