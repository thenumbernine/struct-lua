#!/usr/bin/env luajit
local ffi = require 'ffi'
local assert = require 'ext.assert'
local tolua = require 'ext.tolua'
local struct = require 'struct'

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
assert.eq(ffi.sizeof(A), ffi.sizeof'int')
print(A.code)
assert.is(A, struct)

local a = A()
assert.is(a, struct)--A) -- hmm, 'A' is proly a ctype, so class.isa doesn't care about its relationship in luajit ffi...
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
assert.is(B, struct)
assert.eq(ffi.sizeof(B), 4 * ffi.sizeof'int')

print(B.code)
local b = B()
assert.is(b, struct) --B)
print(b)
print(tolua(b:toLua()))
-- anonymous inner works
print(b.s[0], b.s[1], b.s[2], b.s[3])
print(b.a, b.b, b.c, b.c)

local T = struct{
	ctypeOnly = true,
	fields = {
		{name='a', type='int'},
		{name='b', type='float'},
	},
	metatable = function(mt)
	end,
}
assert.is(T, struct)
print(T)
local t = T()
print(t)

local P = struct{
	ctypeOnly = true,	-- ctypeOnly
	fields = {
		{name = 'a', type='double'},
		{name = 't', type = T},
	},
}
assert.is(P, struct)
print(P)
local p = P()
print(p)

-- ctypeOnly of anonymous-inline of ctypeOnly

local Q = struct{
	ctypeOnly = true,
	fields = {
		{
			type = struct{
				anonymous = true,
				fields = {
					{name = 't', type = T},
				},
			},
		},
	},
}
assert.is(Q, struct)
print(Q)
local q = Q()
print(q)

-- ctypeOnly of anonymous-inline of ctypeOnly of ctypeOnly

local R = struct{
	ctypeOnly = true,
	fields = {
		{
			type = struct{
				anonymous = true,
				fields = {
					{name = 'p', type = P},
				},
			},
		},
	},
}
assert.is(R, struct)
print(R)
local r = R()
print(r)

--[[ if you have a named type that uses a ctype ...
-- this is asking for trouble though, because name implies cdef, but cdef doesn't work with $ params.
local S = struct{
	cdef = true,
	name = 'S',
	fields = {
		{name = 'p', type=P},
	},
}
assert.is(S, struct)
print(S)
local s = S()
print(s)
--]]
