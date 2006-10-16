function state = read_state( file_name )
% read_state.m reads prior_state_diagnostics -type files.
%
% USAGE: state = read_state( file_name )
%

% Data Assimilation Research Testbed -- DART
% Copyright 2004-2006, Data Assimilation Research Section
% University Corporation for Atmospheric Research
% Licensed under the GPL -- www.gpl.org/licenses/gpl.html

% <next three lines automatically updated by CVS, do not edit>
% $Id$
% $Source$
% $Name$

fid = fopen(file_name) ;
%fid = fopen('prior_state_diagnostics') ;
global_meta_data = fgetl(fid);
model_size = fscanf(fid, '%f', 1);
copies_per_time = fscanf(fid, '%f', 1);





% Read in the per copy meta data
for i = 1:copies_per_time,
   index = fscanf(fid, '%f', 1);
   copy_meta_data(i).index = index;
   string = fgetl(fid);
   copy_meta_data(i).string = string;
end

% Read locat header (should test for this)
header = fgetl(fid);

% If we stay with this approach, need modules to read each piece
% That are swapped in and out for matlab (how to automate?)

% Read the locations (should be sub-module) for each state variable
location = 0;
for i = 1:model_size,
% Read loc1d header, check for error at some point
   header = fgetl(fid);
   location(i) = fscanf(fid, '%G', 1);
% Have to read to get end of line (should be able to work around)
   header = fgetl(fid);
end


% Loop to read for many different times
num_times = 200;
% Need to look at storage order and efficiency
state = zeros(num_times, copies_per_time, model_size);

for j = 1:num_times,
% Start reading the output for each copy at current time
   for i = 1:copies_per_time, 
      time = fscanf(fid, '%d', 2);
      header = fgetl(fid);

% Read fcopy header; should check
      header = fgetl(fid);

%Read the copy index
      copy = fscanf(fid, '%d', 1);
      header = fgetl(fid);

% Read in the state vector, model_size
      state(j, i, :) = transpose(fscanf(fid, '%G', model_size));
      header = fgetl(fid);
   end

end

