function [decay_ms, standd] = capture()

%% Clear MATLAB environment
clc;
clear;

%% ********** Parameters to change **********

info.sample = 'T18';          % Photonic Chip 
info.laserPulseWidth = '0.5ms'; % Laser pulse width
info.laserCurrent = '300mA';  % Laser driver current
info.user = 'Tarun';
info.nCaptures = 10;          % Number of captures to average over
info.glucosenseDevice = 2;    % Glucosense device used (1, 2, 3)

% -- Picoscope Settings -- %
%channel A range and offset - may need to change depending on signal level
range = 50;                   % Range in mV (50 or 100)
analogueOffset = -0.230;      % Analogue offset in mV

% -- Saving CSV -- %
storeCSV = true;             % Store data as a CSV (true / false)

%% End of user parameters 

% Use if serial device is not properly closed
% delete(instrfindall)

% TODO: why is it limited to <100ms?
%data truncation values before curve fitting
t_curvefit_start = 1e-3;
t_curvefit_stop = 98e-3;

%% Set path to dlls and functions
addpath(genpath(fileparts(mfilename('fullpath'))));
cd(fileparts(mfilename('fullpath')));

%% Load in enumerations and structures
[methodinfo, structs, enuminfo, ThunkLibName] = PS3000aMFile;

%% Declare variables
global data;

data.TRUE = 1;
data.FALSE = 0;

data.BUFFER_SIZE = 12000;   %12219;

data.timebase = 1024;     % ~1 MS/s (320XA/B)
%data.timebase = 127       % 1 MS/s (340XA/B)
data.oversample = 1;

data.scaleVoltages = data.TRUE;
data.inputRangesmV = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];

plotData = data.FALSE;    % Set to true to plot data

%% Device Connection

% Create device
ps3000a_obj = icdevice('PS3000a_IC_drv', ''); % Specify serial number as 2nd argument if required.

% Connect device
connect(ps3000a_obj);

%% Show unit information - Todo can remove

%info_status = invoke(ps3000a_obj, 'GetUnitInfo')

%% Obtain Maximum & Minimum values 
max_val_status = invoke(ps3000a_obj, 'ps3000aMaximumValue');
min_val_status= invoke(ps3000a_obj, 'ps3000aMinimumValue');

%% Channel settings

% Channel A (decay signal)
channelA = enuminfo.enPS3000AChannel.PS3000A_CHANNEL_A;
channelSettings(1).enabled = data.TRUE;
channelSettings(1).DCCoupled = data.TRUE;

%channel A range and offset - may need to change depending on signal level
%channelSettings(1).range = enuminfo.enPS3000ARange.PS3000A_100MV;
%channelSettings(1).range = enuminfo.enPS3000ARange.PS3000A_50MV;

switch range
    case 50
        channelSettings(1).range = enuminfo.enPS3000ARange.PS3000A_50MV;
    case 100
        channelSettings(1).range = enuminfo.enPS3000ARange.PS3000A_100MV;
end

channelSettings(1).analogueOffset = analogueOffset;


% Channel B (trigger)
channelB = enuminfo.enPS3000AChannel.PS3000A_CHANNEL_B;
channelSettings(2).enabled = data.TRUE;
channelSettings(2).DCCoupled = data.TRUE;
channelSettings(2).range = enuminfo.enPS3000ARange.PS3000A_5V;
channelSettings(2).analogueOffset = 0;

set_ch_a_status = invoke(ps3000a_obj, 'ps3000aSetChannel', channelA, ...
    channelSettings(1).enabled, channelSettings(1).DCCoupled, ...
    channelSettings(1).range, channelSettings(1).analogueOffset);

set_ch_b_status = invoke(ps3000a_obj, 'ps3000aSetChannel', channelB, ...
    channelSettings(2).enabled, channelSettings(2).DCCoupled, ...
    channelSettings(2).range, channelSettings(2).analogueOffset);

%% Set Simple Trigger

enable = data.TRUE;
source = enuminfo.enPS3000AChannel.PS3000A_CHANNEL_B;
threshold = mv2adc(2500, data.inputRangesmV(channelSettings(2).range + 1), ps3000a_obj.maxValue);
direction = enuminfo.enPS3000AThresholdDirection.PS3000A_FALLING;
delay = 0;              
autoTrigger_ms = 10000; % 10s timeout before autotriggering

trigger_status = invoke(ps3000a_obj, 'ps3000aSetSimpleTrigger', ...
    enable, source, threshold, direction, delay, autoTrigger_ms);

%% Get Timebase

timeIndisposed = 0;
maxSamples = data.BUFFER_SIZE;
timeIntNs = 0;
segmentIndex = 0;

[get_timebase_status, timeIntNs1, maxSamples1] = invoke(ps3000a_obj, 'ps3000aGetTimebase', ...
        data.timebase, data.BUFFER_SIZE, ...
        timeIntNs, data.oversample, maxSamples, segmentIndex);

%% Setup Number of Captures and Memory Segments
nCaptures = info.nCaptures;

% Segment the memory
[mem_segments_status, maxSamples] = invoke(ps3000a_obj, 'ps3000aMemorySegments', ...
    nCaptures);

% Set the number of captures
num_captures_status = invoke(ps3000a_obj, 'ps3000aSetNoOfCaptures', nCaptures);

%% Run Block

preTriggerSamples = 0;
postTriggerSamples = data.BUFFER_SIZE - preTriggerSamples;
segmentIndex = 0;

disp('Capturing data');

% Run block and retry if power source not set correctly
retry = 1;
tic;
while retry == 1
    
    [run_block_status, timeIndisposedMs] = invoke(ps3000a_obj, 'ps3000aRunBlock', ...
        preTriggerSamples, postTriggerSamples, data.timebase, ...
        data.oversample, segmentIndex);

    % Check power status
    if run_block_status ~= PicoStatus.PICO_OK

        if (run_block_status == PicoStatus.PICO_POWER_SUPPLY_CONNECTED || ...
                run_block_status == PicoStatus.PICO_POWER_SUPPLY_NOT_CONNECTED || ...
                run_block_status == PicoStatus.PICO_POWER_SUPPLY_UNDERVOLTAGE)

            %change_power_src_status = invoke(ps3000a_obj, 'ChangePowerSource', run_block_status)
            change_power_src_status = ps3000aChangePowerSource(ps3000a_obj, run_block_status);

        else

            % Display error code in Hexadecimal
            fprintf('ps3000aRunBlock status: 0x%X', run_block_status);

        end

    else

        retry = 0;

    end
    
end

% Confirm if device is ready
[status, ready] = invoke(ps3000a_obj, 'ps3000aIsReady');

while ready == 0
   
    [status, ready] = invoke(ps3000a_obj, 'ps3000aIsReady');

end
toc

disp('Capture complete');

%% Stop the device

stop_status = invoke(ps3000a_obj, 'ps3000aStop');

%% Get Number of Captures

[num_captures_status, nCompleteCaptures] = invoke(ps3000a_obj, 'ps3000aGetNoOfCaptures');

%% Set Data Buffer and Get Values

channelA = enuminfo.enPS3000AChannel.PS3000A_CHANNEL_A;
buffer_length = preTriggerSamples + postTriggerSamples;
buffer_ratio_mode = enuminfo.enPS3000ARatioMode.PS3000A_RATIO_MODE_NONE;

pBufferChA = libpointer('int16Ptr', zeros(buffer_length, nCompleteCaptures));

% Obtain data values for each capture, setting the data buffer in turn.
for i = 1 : nCompleteCaptures
    
    %fprintf('Capture %d:\n', i);
    
    temp_buffer = libpointer('int16Ptr', zeros(buffer_length, 1));
    segmentIndex = i-1;
    
    status_set_db = invoke(ps3000a_obj, 'ps3000aSetDataBuffer', ... 
        channelA, temp_buffer, ...
        buffer_length, segmentIndex, buffer_ratio_mode);

    startIndex = 0;
    downSampleRatio = 1;
    downSampleRatioMode = enuminfo.enPS3000ARatioMode.PS3000A_RATIO_MODE_NONE;
    overflow = 0;

    % Get Values
    
    [get_values_status, numSamples, overflow] = invoke(ps3000a_obj, ...
        'ps3000aGetValues', startIndex, ...
        buffer_length, downSampleRatio, downSampleRatioMode, ...
        segmentIndex, overflow);
    
    if(get_values_status ~= PicoStatus.PICO_OK)
    
        fprintf('ps3000aGetValues status: 0x%X', get_values_status);
        plotData = data.FALSE;
        
    else
        
        %assign data to buffer
        pBufferChA.value(:, i) = temp_buffer.value(:, 1);

    end

end

%% Convert data values to milliVolt values

voltage_range_chA = data.inputRangesmV(channelSettings(1).range + 1);

% Buffer to hold data values

buffer_a = get(pBufferChA, 'Value');

buffer_a_mv = zeros(numSamples, nCompleteCaptures);

for m = 1 : nCompleteCaptures
    
    buffer_a_mv(:, m) = adc2mv(buffer_a(:, m), voltage_range_chA, ps3000a_obj.maxValue);

end

%% Disconnect device

disconnect(ps3000a_obj);

%% Calculate mean values (along 2nd array dimension - columns)

buffer_a_mean = mean(buffer_a,2);
buffer_a_mv_mean = mean(buffer_a_mv,2);

%% Plot data

if (plotData == data.TRUE)

    figure;

    % Time axis
    t_ns = double(timeIntNs1) * double([0:numSamples - 1]);
    t = t_ns / 1000000;
    t = t';

    plot(t, buffer_a_mv_mean);
    %plot(t,buffer_a_mv(:,1))  % Plot a single decay
    xlabel('Time (ms)');
    ylabel('Voltage (mV)');

end

%% Fit curve

%truncate data
t_samp = (double(timeIntNs1))*1e-9;
t_trun_start = ceil(t_curvefit_start/t_samp) + 1;
t_trun_stop = floor(t_curvefit_stop/t_samp);
ydata = buffer_a_mv_mean(t_trun_start:t_trun_stop);
xdata = 0:t_samp:((length(ydata)-1)*t_samp);
xdata = xdata';

[decay_ms, standd] = curve_fit2(xdata,ydata);

result.decay_ms = decay_ms;
result.standd = standd;

%% Save data in .MAT file

timestamp = datestr(now(),'yyyymmddHHMMSS');
info.timestamp = timestamp;

filename = [timestamp '.MAT'];
f = fullfile('Data\mat\',filename);
save(f, 'info', 'buffer_a_mv', 'buffer_a_mv_mean', 'timeIntNs1',...
    'result', 'timestamp', 't');


if storeCSV == true
    fname =  ['Data\CSV\',timestamp,'.csv'];
    fid = fopen(fname, 'w');
    % Header
    fprintf(fid, 'Time, Mean, ');
    
    for i = 1:nCaptures
        fprintf(fid, '%d,', i);
    end
    fprintf(fid, '\n');
        
    fclose(fid)
    % Data
    CSVdata = [timedata, buffer_a_mv_mean, buffer_a_mv];
    dlmwrite(fname, CSVdata, '-append'); % Append header
    
end

end