--[[
where is this used?
cl/obj/env.lua
efesoln-cl/efe.lua
super_metroid_randomizer/
ff6-hacking/editor-lua
ff6-hacking/zst-hacking/decode/zst-patch.lua
ff6-randomizer/
ljvm/
mesh/readfbx.lua
vec-ffi/create_vec.lua
hydro-cl
modules
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
local string = require 'ext.string'
local op = require 'ext.op'
local class = require 'ext.class'
local template = require 'template'
local showcode = require 'template.showcode'
local struct = class()

-- [=[ begin functions for child metatable classes

-- 'isa' for Lua classes and ffi metatypes
-- TODO similar to ext.class ...
function struct.isa(cl, obj)
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
	-- else return false?
	end
	local isaSet = op.safeindex(obj, 'isaSet')
	if not isaSet then return false end
	return isaSet[cl] or false
end

-- iterate across all named fields of the struct
-- including anonymous-inner structs
-- TODO just use __pairs ? though note that __pairs metamethod doesn't exist in <=5.1
function struct:fielditer()
	return self.fielditerinner, {
		self = self,
		fields = table(self.fields),
	}
end
-- static method, used with the fielditer
function struct.fielditerinner(state)
	local self = state.self
	if #state.fields == 0 then return end
	local field = state.fields:remove(1)
	if field.no_iter then return struct.fielditerinner(state) end

	local ctype = field.type
	if field.name then
		assert(not field.anonymous)
		return field.name, ctype, field
	end
	assert(ctype.anonymous)
	if struct:isa(ctype) then
		assert(ctype.fields)
		for i=#ctype.fields,1,-1 do
			state.fields:insert(1, ctype.fields[i])
		end
		return struct.fielditerinner(state)
	end
end

function struct:toLua()
	local result = {}
	for name, ctype, field in self:fielditer() do
		if not field.no_tolua then
			local value = self[name]
			if struct:isa(ctype) then	-- TODO just test .toLua ?
				value = value:toLua()
			end
			result[name] = value
		end
	end
	return result
end

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

function struct:fieldToString(name, ctype)
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
end

struct.__concat = string.concat

-- assigned to metatable.new
-- I'd put it in struct:new, but that's already being used to create new structs...
local function newmember(mt, ...)
	return ffi.new(mt.name, ...)
end

-- this depends on :unpack() , which is defined in the codegen below
-- TODO between this and ffi.cpp.vector, one is toTable the other is totable ... which to use?
function struct:toTable()
	return {self:unpack()}
end

--]=] end functions for child metatable classes

--[[
this generate both the C and C++ code
then ffi.cdef's the C code only

args:
	name = (optional) struct name
	anonymous = (optional) set to 'true' for inner-anonymous structs
		either name or anonymous must be set
	union = (optional) set to 'true' for unions, default false for structs
	metatable = function(metatable) for transforming the metatable before applying it via `ffi.metatype`
	cdef = (optional) set to 'false' to avoid calling ffi.cdef on the generated code
	packed = (optional) set to 'true' to add __attribute__((packed)) to all fields
	body = (optional) provide extra body code for the C++ generation
	tostringFields = (optional) set to use fields in the serialization

	fields = table of ...
		name = string.  required unless the type is an anonymous struct.
		type = struct-type, cdata, or string of ffi c type
		no_iter = (optional) set to 'true' to omit all iteration, including the following:
		no_tostring = (optional) set to 'true' to omit this from tostring
		no_tolua = (optional) set to 'true' to omit from toLua()
		... tempting to make fields just an enumeration of the integer children ...
		value = (optional) string to set as the default value
		packed = (optional) set to 'true' to add __attribute__((packed)) to this field. TODO more attributes?

TODO
- option to disable the 'typedef' for C structs and just use a `struct <name>` type?
--]]
local function newStruct(args)
	local name = args.name
	local anonymous = args.anonymous
	assert(args.name or args.anonymous, "expected .name or .anonymous")
	local fields = assert(args.fields)
	assert(not struct:isa(fields))
	local codes = {}
	for _,cpp in ipairs{false, true} do
		codes[cpp and 'cpp' or 'c'] = template([[
<?
if name then
	if cpp then
?><?=args.union and "union" or "struct"?> <?=name?> {
<?	else
?>typedef <?=args.union and "union" or "struct"?> <?=name?> {
<?	end
else -- anonymous (inner) structs:
?><?=args.union and "union" or "struct"?> {
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
		if args.packed or field.packed then
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
if cpp and args.body then
?><?=args.body?>
<?
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
				cpp = cpp,
				fields = fields,
				struct = struct,
				args = args,
			}
		)
	end

	local metatype
	local metatable
	local metacode
	local res, err = xpcall(function()
		if args.cdef ~= false then
			ffi.cdef(codes.c)
		end

		-- also in common with my hydro-cl project
		-- consider merging
		metatable = class(struct)
		metatable.name = name
		metatable.anonymous = anonymous
		metatable.fields = fields

		metatable.code = codes.c
		metatable.cppcode = codes.cpp

		metatable.new = newmember	-- new <-> cdata ctor.  so calling the metatable is the same as calling the cdata returned by the metatype.
		metatable.subclass = nil	-- don't allow subclasses.  you can't in C after all.

		-- now that we have struct as 'metatable's metatable
		-- and we have .field assigned,
		-- we can use :fielditer()
		-- and use it to generate code (and inline some functions that would otherwise be slow)
		metacode = template([[
local ffi = require 'ffi'
local metatable, args = ...
local metatype

function metatable:__tostring()
	return '{'
<?
local first = true
for name, ctype, field in metatable:fielditer() do
	if not field.no_tostring then
	-- TODO ctype might not be a string...
	-- TODO before I had so if fieldToString returned {} then I'd just skip it
?>		.. <?=first and '' or "', ' .." ?><?
		if args.tostringFields then
			?>'<?=name?>='..<?
		end
		?>self:fieldToString('<?=name?>', '<?=ctype?>')
<?	end
	first = false
end
?>
		.. '}'
end

metatable.__eq = function(a,b)
	if getmetatable(a) ~= getmetatable(b) then return false end
	return <?
local first = true
for name, ctype in metatable:fielditer() do
?><?=first and '' or ' and '?>a.<?=name?> == b.<?=name?><?
	first = false
end
?>
end

function metatable:unpack()
	return <?
local first = true
for name, ctype in metatable:fielditer() do
?><?=first and '' or ', '?>self.<?=name?><?
	first = false
end
?>
end

-- TODO just use ffi.new ?  but that requires a typename still ...
function metatable:clone()
	return metatype(self:unpack())
end

-- do this in here so metatype can be in here too
-- TODO performance loss due to extra closures?
-- is it worth it from the perf gain from inlining these functions?

if args.metatable then
	args.metatable(metatable)
end
-- if we don't have a name then can we set a metatype?
-- in fact, even if we have a name as a typedef to an anonymous struct,
--  ffi still gives the cdata type a number instead of a name
if metatable.name
-- also if we were told not to cdef then we can't get a metatype
and args.cdef ~= false
then
	-- 'metatype' returned is the ffi.typeof(name)
	metatype = ffi.metatype(metatable.name, metatable)
end

return metatype
]], {
	args = args,
	metatable = metatable,
})
		metatype = assert(load(metacode))(metatable, args)
	end, function(err)
		return '\n'
			..(codes.c and ('c code:\n'
			..showcode(codes.c)..'\n') or '')
			..(codes.cpp and ('c++ code:\n'
			..showcode(codes.cpp)..'\n') or '')
			..(metacode and ('inline metamethod code:\n'
			..showcode(metacode)..'\n') or '')
			..tostring(err)..'\n'
			..debug.traceback()
	end)
	if not res then error(err) end

	assert(struct:isa(metatable))
	if metatype then
		assert(struct:isa(metatype))
	end

	-- TODO or maybe I should return the metatable always
	--  and rely on ffi.typeof(name) for getting its metatype?
	return metatype or metatable
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

-- 'struct' is / should be the parent class of all created structures
return struct
