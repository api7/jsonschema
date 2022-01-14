# Makefile basic env setting
.DEFAULT_GOAL := help


# Makefile ARGS
OR_EXEC ?= $(shell which openresty)
LUA_JIT_DIR ?= $(shell ${OR_EXEC} -V 2>&1 | grep prefix | grep -Eo 'prefix=(.*)/nginx\s+--' | grep -Eo '/.*/')luajit
LUAROCKS_VER ?= $(shell luarocks --version | grep -E -o  "luarocks [0-9]+.")
LUA_PATH ?= ./lib/?.lua;./deps/lib/lua/5.1/?.lua;./deps/share/lua/5.1/?.lua;;
LUA_CPATH ?= ./deps/lib/lua/5.1/?.so;;

# LUAROCKS PATCH
ifeq ($(LUAROCKS_VER),luarocks 3.)
	luarocks install --lua-dir=$(LUA_JIT_DIR) rockspec/jsonschema-master-0.rockspec --only-deps --tree=deps --local
else
	luarocks install rockspec/jsonschema-master-0.rockspec --only-deps --tree=deps --local
endif


# Makefile ENV
ENV_OS_NAME ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
ENV_RESTY   ?= LUA_PATH="$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty

# AWK patch for mawk
ifneq ($(shell command -v gawk),)
	ENV_HELP_AWK_RULE ?= '{ if(match($$0, /^\s*\#{3}\s*([^:]+)\s*:\s*(.*)$$/, res)){ printf("    make %-15s : %-10s\n", res[1], res[2]) } }'
else
	ENV_HELP_AWK_RULE := '{ if(match($$0, /^\#\#\#([^:]+):(.*)$$/)){ split($$0, res, ":"); gsub(/^\#\#\#[ ]*/, "", res[1]); _desc=$$0; gsub(/^\#\#\#([^:]+):[ \t]*/, "", _desc); printf("    make %-15s : %-10s\n", res[1], _desc) } }'
endif

# ENV patch for darwin
ifeq ($(ENV_OS_NAME), darwin)
	ENV_HELP_AWK_RULE := '{ if(match($$0, /^\#{3}([^:]+):(.*)$$/)){ split($$0, res, ":"); gsub(/^\#{3}[ ]*/, "", res[1]); _desc=$$0; gsub(/^\#{3}([^:]+):[ \t]*/, "", _desc); printf("    make %-15s : %-10s\n", res[1], _desc) } }'
endif


# Makefile basic extension function
_color_red    =\E[1;31m
_color_green  =\E[1;32m
_color_yellow =\E[1;33m
_color_blue   =\E[1;34m
_color_wipe   =\E[0m


define func_echo_status
	printf "[$(_color_blue) info $(_color_wipe)] %s\n" $(1)
endef


define func_echo_warn_status
	printf "[$(_color_yellow) info $(_color_wipe)] %s\n" $(1)
endef


define func_echo_success_status
	printf "[$(_color_green) info $(_color_wipe)] %s\n" $(1)
endef


# Makefile target
### help : Show Makefile rules
.PHONY: help
help:
	@$(call func_echo_success_status, "Makefile rules:")
	@echo
	@awk $(ENV_HELP_AWK_RULE) Makefile
	@echo


### dev : Create a development ENV
.PHONY: deps
dev:
	@$(call func_echo_status, "$@ -> [ Start ]")
	git submodule update --init --recursive
	mkdir -p deps
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### test : Run the test case
.PHONY: test
test:
	@$(call func_echo_status, "$@ -> [ Start ]")
	$(ENV_RESTY) t/draft4.lua
	$(ENV_RESTY) t/draft6.lua
	$(ENV_RESTY) t/draft7.lua
	$(ENV_RESTY) t/default.lua
	$(ENV_RESTY) t/200more_variables.lua
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### clean : Clean the test case
.PHONY: clean
clean:
	@$(call func_echo_status, "$@ -> [ Start ]")
	@rm -rf deps
	@$(call func_echo_success_status, "$@ -> [ Done ]")
