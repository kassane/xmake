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
-- @file        main.lua
--

-- imports
import("core.base.option")
import("core.base.global")
import("core.base.hashset")
import("core.project.config")
import("core.project.project")
import("core.platform.platform")
import("private.detect.find_platform")
import("core.cache.localcache")
import("scangen")
import("menuconf", {alias = "menuconf_show"})
import("configfiles", {alias = "generate_configfiles"})
import("configheader", {alias = "generate_configheader"})
import("private.action.require.install", {alias = "install_requires"})

-- filter option
function _option_filter(name)
    local options =
    {
        target      = true
    ,   file        = true
    ,   root        = true
    ,   yes         = true
    ,   quiet       = true
    ,   confirm     = true
    ,   project     = true
    ,   verbose     = true
    ,   diagnosis   = true
    ,   require     = true
    }
    return not options[name]
end

-- host changed?
function _host_changed()
    return os.host() ~= config.read("host")
end

-- need check
function _need_check(changed)

    -- clean?
    if not changed then
        changed = option.get("clean")
    end

    -- get the current mtimes
    local mtimes = project.mtimes()

    -- get the previous mtimes
    if not changed then
        local mtimes_prev = localcache.get("config", "mtimes")
        if mtimes_prev then

            -- check for all project files
            for file, mtime in pairs(mtimes) do

                -- modified? reconfig and rebuild it
                local mtime_prev = mtimes_prev[file]
                if not mtime_prev or mtime > mtime_prev then
                    changed = true
                    break
                end
            end
        end
    end

    -- xmake has been updated? force to check config again
    -- we need clean the dirty config cache of the old version
    if not changed then
        if os.mtime(path.join(os.programdir(), "core", "main.lua")) > os.mtime(config.filepath()) then
            changed = true
        end
    end

    -- update mtimes
    localcache.set("config", "mtimes", mtimes)

    -- changed?
    return changed
end

-- check target
function _check_target(target)
    for _, depname in ipairs(target:get("deps")) do
        assert(depname ~= target:name(), "the target(%s) cannot depend self!", depname)
        local deptarget = project.target(depname)
        assert(deptarget, "unknown target(%s) for %s.deps!", depname, target:name())
        _check_target(deptarget)
    end
end

-- check targets
function _check_targets(targetname)
    assert(not project.is_loaded(), "project and targets may have been loaded early!")
    if targetname == "all" then
        for _, target in pairs(project.targets()) do
            _check_target(target)
        end
    else
        local target = project.target(targetname)
        assert(target, "unknown target: %s", targetname)
        _check_target(target)
    end
end

-- check target toolchains
function _check_target_toolchains()
    -- check toolchains configuration for all target in the current project
    -- @note we must check targets after loading options
    for _, target in pairs(project.targets()) do
        if target:is_enabled() and (target:get("toolchains") or
                                    not target:is_plat(config.get("plat")) or
                                    not target:is_arch(config.get("arch"))) then
            local target_toolchains = target:get("toolchains")
            if target_toolchains then
                target_toolchains = hashset.from(table.wrap(target_toolchains))
                for _, toolchain_inst in pairs(target:toolchains()) do
                    -- check toolchains for `target/set_toolchains()`
                    if not toolchain_inst:check() and target_toolchains:has(toolchain_inst:name()) then
                        raise("toolchain(\"%s\"): not found!", toolchain_inst:name())
                    end
                end
            else
                -- check platform toolchains for `target/set_plat()`
                local ok, errors = target:platform():check()
                if not ok then
                    raise(errors)
                end
            end
        end
    end
end

-- config target
function _config_target(target)
    for _, rule in ipairs(target:orderules()) do
        local on_config = rule:script("config")
        if on_config then
            on_config(target)
        end
    end
    local on_config = target:script("config")
    if on_config then
        on_config(target)
    end
end

-- config targets
function _config_targets(targetname)
    if targetname == "all" then
        for _, target in ipairs(project.ordertargets()) do
            if target:is_enabled() then
                _config_target(target)
            end
        end
    else
        local target = project.target(targetname)
        assert(target, "unknown target: %s", targetname)
        for _, dep in ipairs(target:orderdeps()) do
            _config_target(dep)
        end
        _config_target(target)
    end
end

-- main entry
function main(opt)

    -- avoid to run this task repeatly
    opt = opt or {}
    if _g.configured then return end
    _g.configured = true

    -- scan project and generate it if xmake.lua not exists
    local autogen = false
    local trybuild = option.get("trybuild")
    if not os.isfile(project.rootfile()) and not trybuild then
        autogen = utils.confirm({default = false, description = "xmake.lua not found, try generating it"})
        if autogen then
            scangen()
        else
            os.exit()
        end
    end

    -- check the working directory
    if not option.get("project") and not option.get("file") and os.isdir(os.projectdir()) then
        if path.translate(os.projectdir()) ~= path.translate(os.workingdir()) then
            wprint([[You are working in the project directory(%s) and you can also
force to build in current directory via run `xmake -P .`]], os.projectdir())
        end
    end

    -- lock the whole project
    project.lock()

    -- enter menu config
    local options_changed = false
    if option.get("menu") then
        options_changed = menuconf_show()
    end

    -- the target name
    local targetname = option.get("target") or "all"

    -- load the project configure
    --
    -- priority: option > option_cache > global > option_default > config_check > project_check > config_cache
    --

    -- get the options
    local options = nil
    for name, value in pairs(option.options()) do
        if _option_filter(name) then
            options = options or {}
            options[name] = value
        end
    end

    -- override configure from the options or cache
    local options_history = {}
    if not option.get("clean") and not autogen then
        options_history = localcache.get("config", "options") or {}
        options = options or options_history
    end
    for name, value in pairs(options) do

        -- options is changed by argument options?
        options_changed = options_changed or options_history[name] ~= value

        -- @note override it and mark as readonly (highest priority)
        config.set(name, value, {readonly = true})
    end

    -- merge the cached configure
    --
    -- @note we cannot load cache config when switching platform, arch ..
    -- so we need known whether options have been changed
    --
    local configcache_loaded = false
    if not options_changed and not option.get("clean") and not _host_changed() then
        configcache_loaded = config.load()
    end

    -- merge the global configure
    for name, value in pairs(global.options()) do
        if config.get(name) == nil then
            config.set(name, value)
        end
    end

    -- merge the default options
    for name, value in pairs(option.defaults()) do
        if _option_filter(name) and config.get(name) == nil then
            config.set(name, value)
        end
    end

    -- merge the project options after default options
    for name, value in pairs(project.get("config")) do
        value = table.unwrap(value)
        assert(type(value) == "string" or type(value) == "boolean" or type(value) == "number", "set_config(%s): unsupported value type(%s)", name, type(value))
        if not config.readonly(name) then
            config.set(name, value)
        end
    end

    -- find default platform and save to configuration
    local plat, arch = find_platform({global = true})
    assert(plat == config.plat())
    assert(arch == config.arch())

    -- load platform instance
    local instance_plat = platform.load(plat, arch)

    -- merge the checked configure
    local recheck = _need_check(options_changed or not configcache_loaded or autogen)
    if recheck then

        -- clear and flush local cache to disk
        localcache.clear("config")
        localcache.clear("detect")
        localcache.clear("option")
        localcache.clear("package")
        localcache.clear("toolchain")
        localcache.save()

        -- check platform
        instance_plat:check()

        -- check project options
        if not trybuild then
            project.check()
        end
    end

    -- translate the build directory
    local buildir = config.get("buildir")
    if buildir and path.is_absolute(buildir) then
        config.set("buildir", path.relative(buildir, project.directory()), {readonly = true, force = true})
    end

    -- only config for building project using third-party buildsystem
    if not trybuild then

        -- install and update requires
        local require_enable = option.boolean(option.get("require"))
        if (recheck or require_enable) and require_enable ~= false then
            install_requires()
        end

        -- check target and ensure to load all targets, @note we must load targets after installing required packages,
        -- otherwise has_package() will be invalid.
        _check_targets(targetname)

        -- update the config files
        if recheck then
            generate_configfiles()
            generate_configheader()
        end

        -- check target toolchains
        if recheck then
            _check_target_toolchains()
        end
    end

    -- config targets
    _config_targets(targetname)

    -- dump config
    if option.get("verbose") and not opt.disable_dump then
        config.dump()
    end

    -- save options and config cache
    config.save()
    localcache.set("config", "options", options)
    localcache.save("config")

    -- unlock the whole project
    project.unlock()
end
