OR_EXEC ?= $(shell which openresty)
LUA_JIT_DIR ?= $(shell ${OR_EXEC} -V 2>&1 | grep prefix | grep -Eo 'prefix=(.*?)/nginx' | grep -Eo '/.*/')luajit
LUAROCKS_VER ?= $(shell luarocks --version | grep -E -o  "luarocks [0-9]+.")
LUA_PATH ?= $(shell luajit -e "print(package.path)")
LUA_CPATH ?= $(shell luajit -e "print(package.cpath)")


### help:         Show Makefile rules.
.PHONY: help
help:
	@echo Makefile rules:
	@echo
	@grep -E '^### [-A-Za-z0-9_]+:' Makefile | sed 's/###/   /'


### dev:          Create a development ENV
.PHONY: dev
dev:
ifeq ($(LUAROCKS_VER),luarocks 3.)
	luarocks install --lua-dir=$(LUA_JIT_DIR) rockspec/jsonschema-master-0.rockspec --only-deps
	luarocks install --lua-dir=$(LUA_JIT_DIR) luaposix
else
	luarocks install rockspec/jsonschema-master-0.rockspec --only-deps
	luarocks install luaposix
endif


### test:         Run the test case
test:
	LUA_PATH="./lib/?.lua;$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty t/draft4.lua
	LUA_PATH="./lib/?.lua;$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty t/draft6.lua
	LUA_PATH="./lib/?.lua;$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty t/draft7.lua
	LUA_PATH="./lib/?.lua;$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty t/default.lua


### help:         Show Makefile rules.
.PHONY: help
help:
	@echo Makefile rules:
	@echo
	@grep -E '^### [-A-Za-z0-9_]+:' Makefile | sed 's/###/   /'
