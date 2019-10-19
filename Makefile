OR_EXEC ?= $(shell which openresty)
LUA_JIT_DIR ?= $(shell ${OR_EXEC} -V 2>&1 | grep prefix | grep -Eo 'prefix=(.*?)/nginx' | grep -Eo '/.*/')luajit
LUAROCKS_VER ?= $(shell luarocks --version | grep -E -o  "luarocks [0-9]+.")


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
	LUA_PATH='./?.lua;./?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/lib64/lua/5.1/?.lua;/usr/lib64/lua/5.1/?/init.lua'\
		LUA_CPATH='./?.so;/usr/lib64/lua/5.1/?.so;/usr/lib64/lua/5.1/loadall.so'\
		resty t/draft4.lua


### help:         Show Makefile rules.
.PHONY: help
help:
	@echo Makefile rules:
	@echo
	@grep -E '^### [-A-Za-z0-9_]+:' Makefile | sed 's/###/   /'
