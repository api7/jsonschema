OR_EXEC ?= $(shell which openresty)
LUA_JIT_DIR ?= $(shell ${OR_EXEC} -V 2>&1 | grep prefix | grep -Eo 'prefix=(.*?)/nginx' | grep -Eo '/.*/')luajit
LUAROCKS_VER ?= $(shell luarocks --version | grep -E -o  "luarocks [0-9]+.")
LUA_PATH ?= $(shell lua -e "print(package.path)")
LUA_CPATH ?= $(shell lua -e "print(package.cpath)")


### help:         Show Makefile rules.
.PHONY: help
help:
	@echo Makefile rules:
	@echo
	@grep -E '^### [-A-Za-z0-9_]+:' Makefile | sed 's/###/   /'


### dev:          Create a development ENV
.PHONY: dev
dev:
ifeq ($(UNAME),Darwin)
	luarocks install --lua-dir=$(LUA_JIT_DIR) ljsonschema-master-0.rockspec --only-deps
else ifneq ($(LUAROCKS_VER),'luarocks 3.')
	luarocks install ljsonschema-master-0.rockspec --only-deps
else
	luarocks install --lua-dir=/usr/local/openresty/luajit ljsonschema-master-0.rockspec --only-deps
endif


### test:         Run the test case
test:
	LUA_PATH="./?.lua;$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty t/draft4.lua
	LUA_PATH="./?.lua;$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty t/draft6.lua
	LUA_PATH="./?.lua;$(LUA_PATH)" LUA_CPATH="$(LUA_CPATH)" resty t/draft7.lua


### help:         Show Makefile rules.
.PHONY: help
help:
	@echo Makefile rules:
	@echo
	@grep -E '^### [-A-Za-z0-9_]+:' Makefile | sed 's/###/   /'
