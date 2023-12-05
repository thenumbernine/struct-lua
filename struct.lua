--[[
TODO merge with vec-ffi and hydro-cl's struct

also TODO more flexible.
- no default union
- support for anonymous structs
- support for packed

where is this used? since I'm about to overhaul it ...
cl/obj/env.lua		... just uses struct:isa

↑↑↑ fixed ↑↑↑

efesoln-cl/efe.lua
super_metroid_randomizer/
ff6-hacking/editor-lua
ff6-hacking/zst-hacking/decode/zst-patch.lua
ff6-randomizer/
ljvm/
mesh/readfbx.lua
hydro-cl ... has its own version
vec-ffi/create_vec.lua ... is its own version of a sort
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
	anonymous = (optional) true , for inner-anonymous structs
		either name or anonymous must be set
	fields = table of ...
		name = string
		type = struct-type, cdata, or string of ffi c type
		no_iter = (optional) omit all iteration, including the following:
		no_tostring = (optional) omit this from tostring
		no_tolua = (optional) omit from toLua()
	metatable = function(metatable) for transforming the metatable
	cdef = set to 'false' to avoid calling ffi.cdef on the generated code
	union = set true for unions, default false for structs
	packed = 'true' to omit __attribute__((packed)) ... why it was default ...
--]]
local function newStruct(args)
	local name = args.name
	local anonymous = args.anonymous
	assert(args.name or args.anonymous)
	local fields = assert(args.fields)
	local union = args.union
	local packed = args.packed
	if packed == nil then
		packed = struct.packed
	end
	local code = template([[
<?
if name then
?>typedef <?=union and "union" or "struct"?> <?=name?> {
<?
else
?><?=union and "union" or "struct"?> {
<?
end
local ffi = require 'ffi'
local size = 0
for _,field in ipairs(fields) do
	local name = field.name
	local ctype = field.type
	if not name then
?>	<?=ctype.code:gsub('\n', '\n\t')?>
<?	else
		if type(ctype) == 'string' then
			local rest, bits = ctype:match'^(.*):(%d+)$'
			if bits then
				ctype = rest
			end
			local base, array = ctype:match'^(.*)%[(%d+)%]$'
			if array then
				ctype = base
				name = name .. '[' .. array .. ']'
			end
			if bits then
				assert(not array)
				size = size + bits / 8
			else
				size = size + ffi.sizeof(ctype) * (array or 1)
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
?>	<?=ctype?> <? if packed then ?>__attribute__((packed))<? end ?> <?=name or ''?><?=bits and (' : '..bits) or ''?>;
<?	end
end
?>}<?=name and (' '..name) or ''?>;]], 
		{
			ffi = ffi,
			anonymous = anonymous,
			name = name,
			fields = fields,
			struct = struct,
			union = union,
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
		metatable.__index = metatable

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
		if name then
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
