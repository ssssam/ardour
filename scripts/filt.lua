ardour {
	["type"]    = "dsp",
	name        = "Biquad Filter",
	category    = "Filter",
	license     = "MIT",
	author      = "Robin Gareus",
	email       = "robin@gareus.org",
	site        = "http://gareus.org",
	description = [[Example Ardour Lua DSP Plugin]]
}

function dsp_ioconfig ()
	return
	{
		-- allow any number of I/O as long as port-count matches
		{ audio_in = -1, audio_out = -1},
	}
end


function dsp_params ()
	return
	{
		{ ["type"] = "input", name = "Type", min = 0, max = 4, default = 0, enum = true, scalepoints =
			{
				["Peaking"]    = 0,
				["Low Shelf"]  = 1,
				["High Shelf"] = 2,
				["Low Pass"]   = 3,
				["High Pass"]  = 4,
			}
		},
		{ ["type"] = "input", name = "Gain", min = -20, max = 20,    default = 0,    unit="dB" },
		{ ["type"] = "input", name = "Freq", min =  20, max = 20000, default = 1000, unit="Hz", logarithmic = true },
		{ ["type"] = "input", name = "Q",    min = 0.1, max = 8,     default = .707, logarithmic = true },
	}
end

-- translate type parameter to DSP enum
-- http://manual.ardour.org/lua-scripting/class_reference/#ARDOUR.DSP.Biquad.Type
function map_type (t)
	if     t == 1 then
		return ARDOUR.DSP.BiquadType.LowShelf
	elseif t == 2 then
		return ARDOUR.DSP.BiquadType.HighShelf
	elseif t == 3 then
		return ARDOUR.DSP.BiquadType.LowPass
	elseif t == 4 then
		return ARDOUR.DSP.BiquadType.HighPass
	else
		return ARDOUR.DSP.BiquadType.Peaking
	end
end

-- these globals are *not* shared between DSP and UI
local filt -- the biquad filter instance
local cur = {0, 0, 0, 0} -- current parameters
local lpf = 0.03 -- parameter low-pass filter time-constant

function dsp_init (rate)
	self:shmem ():allocate (1) -- shared mem to tell the GUI the samplerate
	local cfg = self:shmem ():to_int (0):array ()
	cfg[1] = rate
	-- http://manual.ardour.org/lua-scripting/class_reference/#ARDOUR:DSP:Biquad
	filt = ARDOUR.DSP.Biquad (rate) -- initialize filter
	lpf = 13000 / rate -- interpolation time constant
end

-- helper functions for parameter interpolation
function param_changed (ctrl)
	if ctrl[1] == cur[1] and ctrl[2] == cur[2] and ctrl[3] == cur[3] and ctrl[4] == cur[4] then
		return false
	end
	return true
end

function low_pass_filter_param (old, new, limit)
	if math.abs (old - new) < limit  then
		return new
	else
		return old + lpf * (new - old)
	end
end

-- apply parameters, re-compute filter coefficients if needed
function apply_params (ctrl)
	if not param_changed (ctrl) then
		return
	end

	if cur[1] ~= ctrl[1] then
		-- reset filter state when type changes
		filt:reset ()
		for k = 1,4 do cur[k] = ctrl[k] end
	else
		-- low-pass filter ctrl parameter values, smooth transition
		cur[2] = low_pass_filter_param (cur[2], ctrl[2], 0.1) -- gain/dB
		cur[3] = low_pass_filter_param (cur[3], ctrl[3], 1.0) -- freq/Hz
		cur[4] = low_pass_filter_param (cur[4], ctrl[4], 0.01) -- quality
	end

	filt:compute (map_type (cur[1]), cur[3], cur[4], cur[2])
end


-- the actual DSP callback
function dsp_run (ins, outs, n_samples)
	local changed = false
	local siz = n_samples
	local off = 0

	-- if a parameter was changed, process at most 64 samples at a time
	-- and interpolate parameters until the current settings match
	-- the target values
	if param_changed (CtrlPorts:array ()) then
		changed = true
		siz = 64
	end

	while n_samples > 0 do
		if changed then apply_params (CtrlPorts:array ()) end
		if siz > n_samples then siz = n_samples end

		-- process all channels
		for c = 1,#ins do
			-- check if output and input buffers for this channel are identical
			-- http://manual.ardour.org/lua-scripting/class_reference/#C:FloatArray
			if ins[c]:sameinstance (outs[c]) then
				filt:run (ins[c]:offset (off), siz) -- in-place processing
			else
				-- http://manual.ardour.org/lua-scripting/class_reference/#ARDOUR:DSP
				ARDOUR.DSP.copy_vector (outs[c]:offset (off), ins[c]:offset (off), siz)
				filt:run (outs[c]:offset (off), siz)
			end
		end

		n_samples = n_samples - siz
		off = off + siz
	end

	if changed then
		-- notify display
		self:queue_draw ()
	end
end


-------------------------------------------------------------------------------
--- inline display

function round (n)
	return math.floor (n + .5)
end

function freq_at_x (x, w)
	-- x-axis pixel for given freq, power-scale
	return 20 * 1000 ^ (x / w)
end

function x_at_freq (f, w)
	-- frequency at given x-axis pixel
	return w * math.log (f / 20.0) / math.log (1000.0)
end

function db_to_y (db, h)
	-- y-axis gain mapping
	if db < -20 then db = -20 end
	if db >  20 then db =  20 end
	return -.5 + 0.5 * h * (1 - db / 20)
end

function grid_db (ctx, w, h, db)
	-- draw horizontal grid line
	local y = -.5 + round (db_to_y (db, h))
	ctx:move_to (0, y)
	ctx:line_to (w, y)
	ctx:stroke ()
end

function grid_freq (ctx, w, h, f)
	-- draw vertical grid line
	local x = -.5 + round (x_at_freq (f, w))
	ctx:move_to (x, 0)
	ctx:line_to (x, h)
	ctx:stroke ()
end

function render_inline (ctx, w, max_h)
	if not filt then
		-- the GUI is separate from the DSP, but the GUI needs to know
		-- the sample-rate that the DSP is using.
		local shmem = self:shmem () -- get shared memory region
		local cfg = shmem:to_int (0):array () -- "cast" into lua-table
		-- instantiate filter (to calculate the transfer function's response)
		filt = ARDOUR.DSP.Biquad (cfg[1])
	end

	-- set filter coefficients if they have changed
	if param_changed (CtrlPorts:array ()) then
		local ctrl = CtrlPorts:array ()
		for k = 1,4 do cur[k] = ctrl[k] end
		filt:compute (map_type (cur[1]), cur[3], cur[4], cur[2])
	end

	-- calc height of inline display
	local h = math.ceil (w * 10 / 16) -- use 16:10 aspect
	h = 2 * round (h / 2) -- with an even number of vertical pixels
	if (h > max_h) then h = max_h end -- but at most max-height

	-- ctx is a http://cairographics.org/ context
	-- http://manual.ardour.org/lua-scripting/class_reference/#Cairo:Context

	-- clear background
	ctx:rectangle (0, 0, w, h)
	ctx:set_source_rgba (.2, .2, .2, 1.0)
	ctx:fill ()

	-- set line width: 1px
	-- Note: a cairo pixel at [1,1]  spans [0.5->1.5 , 0.5->1.5]
	-- hence the offset -0.5 in various move_to(), line_to() calls
	ctx:set_line_width (1.0)

	-- draw grid
	local dash3 = C.DoubleVector ()
	dash3:add ({1, 3})
	ctx:set_dash (dash3, 2) -- dotted line
	ctx:set_source_rgba (.5, .5, .5, .5)
	grid_db (ctx, w, h, 0)
	grid_db (ctx, w, h, 6)
	grid_db (ctx, w, h, 12)
	grid_db (ctx, w, h, 18)
	grid_db (ctx, w, h, -6)
	grid_db (ctx, w, h, -12)
	grid_db (ctx, w, h, -18)
	grid_freq (ctx, w, h, 100)
	grid_freq (ctx, w, h, 1000)
	grid_freq (ctx, w, h, 10000)
	ctx:unset_dash ()

	-- draw transfer function line
	ctx:set_source_rgba (.8, .8, .8, 1.0)
	ctx:move_to (-.5, db_to_y (filt:dB_at_freq (freq_at_x (0, w)), h))
	for x = 1,w do
		local db = filt:dB_at_freq (freq_at_x (x, w))
		ctx:line_to (-.5 + x, db_to_y (db, h))
	end
	ctx:stroke_preserve ()

	-- fill area to zero under the curve
	ctx:line_to (w, -.5 + h * .5)
	ctx:line_to (0, -.5 + h * .5)
	ctx:close_path ()
	ctx:set_source_rgba (.5, .5, .5, .5)
	ctx:fill ()

	return {w, h}
end
