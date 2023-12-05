#!/usr/bin/env luajit
local ffi = require 'ffi'
local struct = require 'struct'
local tolua = require 'ext.tolua'

local union = struct.union

--[[
struct A {
	{a = 'int'},
};
--]]
local A = struct{
	name = 'A',
	fields = {
		{name='a', type='int'},
	},
}
assert(ffi.sizeof(A) == ffi.sizeof'int')
print(A.code)

local a = A()
print(a)
print(tolua(a:toLua()))
print()

--[[
union B {
	int s[4];
	struct {
		int a, b, c, d;
	};
};
--]]
local B = struct{
	name = 'B',
	union = true,
	fields = {
		{name='s', type='int[4]', no_iter=true},
		-- such that type can be a C string or a ffi ctype
		-- notice that typedef struct's anonymous, ffi.typeof will report them as numbers ...
		-- and in that case, you can't get the C type string from the ffi.typeof
		{type=struct{
			-- if you provide a name then the name is used ...
			-- and cdef'd in advance ... 
			-- so it does work ...
			-- but the resulting code looks ugly
			-- 
			-- if you don't use the name then ...
			-- ... ffi can't grab a metatype ...
			-- ... and that means we can't use it ...
			anonymous = true,
			fields = {
				{name='a', type='int'},
				{name='b', type='int'},
				{name='c', type='int'},
				{name='d', type='int'},
			},
		}},
	},
}
assert(ffi.sizeof(B) == 4 * ffi.sizeof'int')

print(B.code)
local b = B()
print(b)
print(tolua(b:toLua()))
-- anonymous inner works
print(b.s[0], b.s[1], b.s[2], b.s[3])
print(b.a, b.b, b.c, b.c)
