--[[
TODO merge with vec-ffi and hydro-cl's struct

also TODO more flexible.
- no default union
- support for anonymous structs
- support for packed

where is this used? since I'm about to overhaul it ...
cl/obj/env.lua		... just uses struct:isa
efesoln-cl/efe.lua
super_metroid_randomizer/
ff6-hacking/editor-lua
ff6-hacking/zst-hacking/decode/zst-patch.lua
ff6-randomizer/
ljvm/
mesh/readfbx.lua
vec-ffi/create_vec.lua

↑↑↑ fixed ↑↑↑

TODO
hydro-cl ... has its own version
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
local string = require 'ext.string'
local op = require 'ext.op'
local class = require 'ext.class'
local template = require 'template'

-- 'isa' for LUa classes and ffi metatypes
local function isa(cl, obj)
	-- if we get a ffi.typeof() then it will be cdata as well, but luckily in ffi, typeof(typeof(x)) == typeof(x)
	local luatype = type(obj)
--print('got lua type', luatype)
	if luatype == 'string'
	or luatype == 'cdata'
	then
		-- luajit is gung-ho on the exceptions, even in cases when identical Lua behavior doesn't throw them (e.g. Lua vs cdata indexing fields that don't exist)
		local res
--print('converting to cdata: '..tostring(obj))
		res, obj = pcall(ffi.typeof, obj)
		if not res then return false end
	elseif luatype ~= 'table' then
	--	return false
	end
	if not op.safeindex(obj, 'isaSet') then return false end
	return obj.isaSet[cl] or false
end

local struct = class()

struct.isa = isa

function struct.dectostr(value)
	return ('%d'):format(value)
end

function struct.hextostr(digits)
	return function(value)
		return ('%0'..digits..'x'):format(value)
	end
end

struct.typeToString = {
	uint8_t = struct.dectostr,
	uint16_t = struct.dectostr,
}

--[[
args:
	name = (optional) struct name
	anonymous = (optional) set to 'true' for inner-anonymous structs
		either name or anonymous must be set
	union = (optional) set to 'true' for unions, default false for structs
	cpp = (optional) set to 'true' to use `struct <name> { ... }` instead of `typedef struct { ... } <name>`
	fields = table of ...
		name = string.  required unless the type is an anonymous struct.
		type = struct-type, cdata, or string of ffi c type
		no_iter = (optional) set to 'true' to omit all iteration, including the following:
		no_tostring = (optional) set to 'true' to omit this from tostring
		no_tolua = (optional) set to 'true' to omit from toLua()
		... tempting to make fields just an enumeration of the integer children ...
		value = (optional) string to set as the default value - but only if cpp is true.
	metatable = function(metatable) for transforming the metatable before applying it via `ffi.metatype`
	cdef = (optional) set to 'false' to avoid calling ffi.cdef on the generated code
	packed = (optional) set to 'true' to add __attribute__((packed)) to all fields ... TODO specify this per-field? or allow both?

	TODO
	- option to disable the 'typedef' for C structs and just use a `struct <name>` type?
	- option to insert code into the struct body (esp for C++)
--]]
local function newStruct(args)
	local name = args.name
	local anonymous = args.anonymous
	assert(args.name or args.anonymous)
	local fields = assert(args.fields)
	local union = args.union
	local packed = args.packed
	local cpp = args.cpp
	local code = template([[
<?
if name then
	if cpp then
?><?=union and "union" or "struct"?> <?=name?> {
<?	else
?>typedef <?=union and "union" or "struct"?> <?=name?> {
<?	end
else -- anonymous (inner) structs:
?><?=union and "union" or "struct"?> {
<?
end
local ffi = require 'ffi'
for _,field in ipairs(fields) do
	local name = field.name
	local ctype = field.type
	if not name then
?>	<?=ctype.code:gsub('\n', '\n\t')?>
<?	else
		local bits
		if type(ctype) == 'string' then
			local rest
			rest, bits = ctype:match'^(.*):(%d+)$'
			if bits then
				ctype = rest
			end
			local base, array = ctype:match'^(.*)%[(%d+)%]$'
			if array then
				ctype = base
				name = name .. '[' .. array .. ']'
			end
		elseif struct:isa(ctype) then
			if ctype.name then
				ctype = ctype.name
			else	-- anonymous struct <-> insert the code here
				ctype = ctype.code
			end
		else
			error("you are here")
		end
?>	<?=ctype?> <?
		if packed then
			?>__attribute__((packed))<?
		end
		?><?=name and (' '..name) or ''
		?><?=bits and (' : '..bits) or ''
		?><?
		if cpp and field.value then
			?> = <?=field.value?><?
		end
		?>;
<?	end
end
if cpp then
?>};<?
else
?>}<?=name and (' '..name) or ''?>;<?
end
?>]],
		{
			ffi = ffi,
			anonymous = anonymous,
			name = name,
			union = union,
			cpp = cpp,
			fields = fields,
			struct = struct,
			packed = packed,
		}
	)

	local metatype
	xpcall(function()
		if args.cdef ~= false then
			ffi.cdef(code)
		end

		assert(not struct:isa(fields))

		-- also in common with my hydro-cl project
		-- consider merging
		local metatable = {
			name = name,
			anonymous = anonymous,
			fields = fields,

			-- TODO vec-ffi's typeCode
			-- ... also check what hydro-cl's struct uses, probably typeCode also
			code = code,

			-- TODO similar to ext.class and vec-ffi/create_vec.lua
			isa = isa,

			-- iterate across all named fields of the struct
			-- including anonymous-inner structs
			-- TODO just use __pairs ?
			fielditer = function(self)
				assert(fields)
				assert(self.fields == fields)
				if self.fielditerinner then
					return coroutine.wrap(function()
						self:fielditerinner(self.fields)
					end)
				else
					-- anonymous?
				end
			end,
			fielditerinner = function(self, fields)
				assert(self.fielditerinner)
				assert(fields)
				assert(type(fields) == 'table')
				for _,field in ipairs(fields) do
					if not field.no_iter then
						local ctype = field.type
						if field.name then
							assert(not field.anonymous)
							coroutine.yield(field.name, ctype, field)
						else
							assert(ctype.anonymous)
							if struct:isa(ctype) then
								assert(ctype.fields)
								self:fielditerinner(ctype.fields)
							end
						end
					end
				end
			end,

			toLua = function(self)
				local result = {}
				for name, ctype, field in self:fielditer() do
					if not field.no_tolua then
						local value = self[name]
						if struct:isa(ctype) then
							value = value:toLua()
						end
						result[name] = value
					end
				end
				return result
			end,
			__tostring = function(self)
				local t = table()
				for name, ctype, field in self:fielditer() do
					if not field.no_tostring then
						assert(name)
						local s = self:fieldToString(name, ctype)
						if s
						-- hmm... bad hack
						and s ~= '{}'
						then
							t:insert((name or '?')..'='..s)
						end
					end
				end
				return '{'..t:concat', '..'}'
			end,
			fieldToString = function(self, name, ctype)
				if struct:isa(ctype) then
					ctype = ctype.name
				end
				-- special for bitflags ...
				if type(ctype) == 'string'
				and ctype:sub(-2) == ':1'
				then
					if self[name] ~= 0 then
						return 'true'
					else
						return nil -- nothing
					end
				end

				return (struct.typeToString[ctype] or tostring)(self[name])
			end,
			__concat = string.concat,
			__eq = function(a,b)
				local function isprim(x)
					return ({
						['nil'] = true,
						boolean = true,
						number = true,
						string = true,
					})[type(x)]
				end
				if isprim(a) or isprim(b) then return rawequal(a,b) end
				for _,field in ipairs(fields) do
					local name = field.name
					local ctype = field.type
					if a[name] ~= b[name] then return false end
				end
				return true
			end,
		}
		-- [[ throws errors if the C field isn't present
		metatable.__index = metatable
		--]]
		--[[ doesn't throw errors if the C field isn't present.  probably runs slower.
		-- but this doesn't help by field detect in the case of cdata unless every single cdef metamethod __index is set to a function instead of a table...
		metatable.__index = function(t,k) return metatable[k] end
		--]]


		-- to match ext.class
		metatable.class = metatable
		metatable.super = struct
		metatable.isaSet = {}
		metatable.isaSet[metatable] = true
		-- TODO merge struct.isaSet here (or is struct a class() ?)
		metatable.isaSet[struct] = true

		if args.metatable then
			args.metatable(metatable)
		end
		-- if we don't have a name then can we set a metatype?
		-- in fact, even if we have a name as a typedef to an anonymous struct,
		--  ffi still gives the cdata type a number instead of a name
		if name
		-- also if we were told not to cdef then we can't get a metatype
		and args.cdef ~= false
		then
			metatype = ffi.metatype(name, metatable)
		else
			-- notice now 'metatype' i.e. what is returned is not a ffi.cdata ...
			metatype = metatable
		end

--[[
		if packed then
			local sizeOfFields = table.mapi(fields, function(field)
				local fieldName = field.name
				local fieldType = field.type
-- TODO what if it's a ctype ...
				local rest, bits = fieldType:match'^(.*):(%d+)$'
				local base, array = fieldType:match'^(.*)%[(%d+)%]$'
				if bits then
					assert(not array)
					return bits / 8
				else
					return ffi.sizeof(fieldType)
				end
			end):sum()
			local sizeof = ffi.sizeof(name)
			if sizeof ~= sizeOfFields then
				error(
					"sizeof("..name..") = "..sizeof.."\n"
					.."sizeof fields = "..sizeOfFields.."\n"
					.."struct "..name.." isn't packed!"
				)
			end
		end
--]]
--[[
		local null = ffi.cast(name..'*', nil)
		local sizeOfFields = table.mapi(fields, function(field)
			local fieldName = field.name
			local fieldType = field.type
			return ffi.sizeof(null[fieldName])
		end):sum()
		if ffi.sizeof(name) ~= sizeOfFields then
			io.stderr:write("struct "..name.." isn't packed!\n")
			for _,field in ipairs(fields) do
				local fieldName = field.name
				local fieldType = field.type
				io.stderr:write('field '..fieldName..' size '..ffi.sizeof(null[fieldName]),'\n')
			end
		end
--]]
	end, function(err)
		io.stderr:write(require 'template.showcode'(code),'\n')
		io.stderr:write(err,'\n',debug.traceback(),'\n')
		os.exit(1)
	end)
assert(struct:isa(metatype))
	-- NOTICE ffi.metatype returns the same as ffi.typeof
	return metatype, code
end

-- instead of creating a struct instance, create a metatype subclass
function struct:new(...)
	return newStruct(...)
end

-- helper function
struct.union = function(args)
	args.union = true
	return struct(args)
end

return struct
