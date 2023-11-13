-- TODO merge with vec-ffi and hydro-cl's struct
local ffi = require 'ffi'
local table = require 'ext.table'
local class = require 'ext.class'
local template = require 'template'

local struct = class()

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
	name
	fields
	metatype
	cdef = set to 'false' to avoid calling ffi.cdef on the generated code
	unionType = optional, if you want access to the struct as a byte array (which I'm using it for most often)
		this defaults to 'uint8_t', but you can override to another type
	unionField = optional, name of the underlying byte array access field,
		default 'ptr'
--]]
local function newStruct(args)
	local name = assert(args.name)
	local fields = assert(args.fields)
	local unionType = args.unionType or 'uint8_t'
	local unionField = args.unionField or 'ptr'
	local code = template([[
typedef union <?=name?> {
	struct {
<?
local ffi = require 'ffi'
local size = 0
for _,kv in ipairs(fields) do
	local name, ctype = next(kv)
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
?>		<?=ctype?> __attribute__((packed)) <?=name?><?=bits and (' : '..bits) or ''?>;
<?
end
?>	};
	<?=unionType?> <?=unionField?>[<?=math.ceil(size / ffi.sizeof(unionType))?>];
} <?=name?>;
]], 	{
			ffi = ffi,
			name = name,
			fields = fields,
			unionType = unionType,
			unionField = unionField,
		}
	)

	local metatype
	xpcall(function()
		if args.cdef ~= false then
			ffi.cdef(code)
		end

		-- also in common with my hydro-cl project
		-- consider merging
		local metatable = {
			name = name,
			fields = fields,

			-- TODO vec-ffi's typeCode
			-- ... also check what hydro-cl's struct uses, probably typeCode also
			code = code,

			-- TODO similar to ext.class and vec-ffi/create_vec.lua
			isa = function(cl, obj)
				-- if we get a ffi.typeof() then it will be cdata as well, but luckily in ffi, typeof(typeof(x)) == typeof(x)
				if type(obj) == 'string'
				or type(obj) == 'cdata'
				then
					-- luajit is gung-ho on the exceptions, even in cases when identical Lua behavior doesn't throw them (e.g. Lua vs cdata indexing fields that don't exist)
					local res
					res, obj = pcall(ffi.typeof, obj)
					if not res then return false end
				elseif type(obj) ~= 'table' then
					return false
				end
				if not obj.isaSet then return false end
				return obj.isaSet[cl] or false
			end,

			toLua = function(self)
				local result = {}
				for _,field in ipairs(fields) do
					local name, ctype = next(field)
					local value = self[name]
					if ctype.toLua then
						value = value:toLua()
					end
					result[name] = value
				end
				return result
			end,
			__tostring = function(self)
				local t = table()
				for _,field in ipairs(fields) do
					local name, ctype = next(field)
					local s = self:fieldToString(name, ctype)
					if s
					-- hmm... bad hack
					and s ~= '{}'
					then
						t:insert(name..'='..s)
					end
				end
				return '{'..t:concat', '..'}'
			end,
			fieldToString = function(self, name, ctype)
				-- special for bitflags ...
				if ctype:sub(-2) == ':1' then
					if self[name] ~= 0 then
						return 'true'
					else
						return nil -- nothing
					end
				end

				return (struct.typeToString[ctype] or tostring)(self[name])
			end,
			__concat = function(a,b)
				return tostring(a) .. tostring(b)
			end,
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
					local name, ctype = next(field)
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
		metatype = ffi.metatype(name, metatable)

		local sizeOfFields = table.mapi(fields, function(kv)
			local fieldName, fieldType = next(kv)
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
--[[
		local null = ffi.cast(name..'*', nil)
		local sizeOfFields = table.map(fields, function(kv)
			local fieldName,fieldType = next(kv)
			return ffi.sizeof(null[fieldName])
		end):sum()
		if ffi.sizeof(name) ~= sizeOfFields then
			io.stderr:write("struct "..name.." isn't packed!\n")
			for _,field in ipairs(fields) do
				local fieldName,fieldType = next(kv)
				io.stderr:write('field '..fieldName..' size '..ffi.sizeof(null[fieldName]),'\n')
			end
		end
--]]
	end, function(err)
		io.stderr:write(require 'template.showcode'(code),'\n')
		io.stderr:write(err,'\n',debug.traceback(),'\n')
		os.exit(1)
	end)
	return metatype, code
end

-- instead of creating a struct instance, create a metatype subclass
function struct:new(...)
	return newStruct(...)
end

return struct
