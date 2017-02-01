! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!
! $Id$

module state_space_diag_mod

!> \defgroup state_space_diag_mod state_space_diag_mod
!> Diagnostic file creation, writing, and closing.
!>
!> Usage:
!>   call init_diag_output(...)
!>   call filter_state_space_diagnostics(...)
!>   call finalize_diag_output(...)
!>
!>   These calls must all be collective calls. This allows tasks other than zero
!>   to write diagnostic information and also allows parallel IO within state_space_diag_mod.
!>
!> Note 'all time steps' means all time steps on the output_interval
!> set in filter.
!> Different options for diagnostic files:
!> 1. Single file - all copies, all time steps in one file.
!>      model_mod::nc_write_model_atts is called which then returns
!>      a flag whether DART should define and write the state variables.
!>      This allows the model to still write whatever it wants to 
!>      the diagnostic file, and still have DART write the state if needed
!>      using the following routines:
!>         * dart_nc_write_model_atts
!>         * dart_nc_write_model_vars
!>
!> 2. One copy per file, but all timesteps
!>      Not sure if there is any desire for this.
!>      Routines to write:
!>         * init_diag_one_copy_per_file
!>         * dart_nc_write_model_atts_one_copy_per_file
!>         * dart_nc_write_model_vars_one_copy_per_file
!>         * finalize_diag_output_one_copy_per_file
!>
!> 3. One copy per file, one timestep
!>      This is for large models
!>      Here IO time is a concern, e.g. 0.1 degree POP where 60% of
!>      the run time of filter is in transposing and reading/writing
!>      restart files.
!>          * This is only for ONE timestep runs. - filter must have the output_interval = 1
!>
!>  A large amount of code in this module was moved from assim_model_mod and smoother_mod.
!>  Some routines are only used by the program rms_diag.f90. It is believed that this program
!>  is not in use. There has been some discusion on whether to deprecate assim_model_type
!>  also.
!>
!> @{

use        types_mod,     only : r8, i8, digits12
use time_manager_mod,     only : time_type, get_time, read_time, write_time,           &
                                 THIRTY_DAY_MONTHS, JULIAN, GREGORIAN, NOLEAP,         &
                                 operator(<), operator(>), operator(+), operator(-),   &
                                 operator(/), operator(*), operator(==), operator(/=), &
                                 get_calendar_type
use location_mod,         only : location_type, read_location, LocationDims
use ensemble_manager_mod, only : ensemble_type, map_task_to_pe, get_copy, &
                                 all_copies_to_all_vars, get_allow_transpose
use assim_model_mod,      only : assim_model_type, get_model_size
use model_mod,            only : nc_write_model_vars, nc_write_model_atts
use adaptive_inflate_mod, only : adaptive_inflate_type
use mpi_utilities_mod,    only : my_task_id, broadcast_flag
use utilities_mod,        only : error_handler, E_MSG, E_ERR, E_DBG, E_WARN, get_unit, &
                                 file_to_text, find_textfile_dims, nc_check, &
                                 register_module, to_upper
use adaptive_inflate_mod, only : do_varying_ss_inflate, do_single_ss_inflate, &
                                 get_is_prior, get_is_posterior
use io_filenames_mod,     only : file_info_type, stage_metadata_type, get_stage_metadata

use state_structure_mod, only : get_num_domains, create_diagnostic_structure, &
                                get_num_variables, get_num_dims, set_var_id, &
                                get_dim_name, get_variable_name, get_dim_length, &
                                get_index_start, get_index_end, get_dim_lengths, &
                                end_diagnostic_structure

use netcdf
use typeSizes ! Part of netcdf?

implicit none
private

public :: init_state_space_diag, &
          netcdf_file_type, &
          init_diag_output, &
          aoutput_diagnostics, &
          finalize_diag_output

! version controlled file description for error handling, do not edit
character(len=256), parameter :: source   = &
   "$URL$"
character(len=32 ), parameter :: revision = "$Revision$"
character(len=128), parameter :: revdate  = "$Date$"

!>@todo some of the routines in here are not currently being used but will be useful for 
!>      reading in single file input.

!-------------------------------------------------------------------------------
!> output (netcdf) file descriptor (diagnostic file handle)
!> basically, we want to keep a local mirror of the unlimited dimension
!> coordinate variable (i.e. time) because dynamically querying it
!> causes unacceptable performance degradation over "long" integrations.
!> The logical model_mod_will_write_state_variables determines whether the model is going
!> to define and write the state variables in the diagnostic files. If .false. dart will
!> define and write the state variables.
type netcdf_file_type
   private
   integer :: ncid                       ! the "unit" -- sorta
   integer :: Ntimes                     ! the current working length
   integer :: NtimesMAX                  ! the allocated length.
   real(digits12),  pointer :: rtimes(:) ! times -- as a 64bit (at least) real
   type(time_type), pointer :: times(:)  ! times -- as the models use
   character(len=80)        :: fname     ! filename ...
   ! The following only applies to single file
   logical :: model_mod_will_write_state_variables = .false.
   integer :: diag_id = -1  ! to access state_structure
end type netcdf_file_type

logical :: module_initialized = .false.

! Global storage for error/message string output
character(len=512)  :: msgstring


!-------------------------------------------------------------------------------

contains


!-------------------------------------------------------------------------------
!> Initialize the state_space_diagnostic module


subroutine init_state_space_diag()

integer :: iunit

if (module_initialized) return

! Print module information
call register_module(source, revision, revdate)

module_initialized = .true.

end subroutine init_state_space_diag


!-------------------------------------------------------------------------------
! DART writing diagnostic files
!-------------------------------------------------------------------------------
!> Write state to the last time slice of a file
!> This routine is called from aoutput_diagnostics if the model_mod
!> nc_write_model_vars has returned 
!> model_mod_will_write_state_varaibles = .false.


subroutine dart_nc_write_model_vars(out_unit, model_state, copyindex, timeindex)

type(netcdf_file_type), intent(in) :: out_unit
real(r8),               intent(in) :: model_state(:)
integer,                intent(in) :: copyindex
integer,                intent(in) :: timeindex

integer, dimension(NF90_MAX_VAR_DIMS) :: dim_lengths
integer, dimension(NF90_MAX_VAR_DIMS) :: start_point
integer :: start_index, end_index
integer :: i
integer :: ndims
integer :: ret ! netcdf return code
integer :: var_id ! netcdf variable id

do i = 1, get_num_variables(out_unit%diag_id)

   start_index = get_index_start(out_unit%diag_id, i)
   end_index = get_index_end(out_unit%diag_id, i)
   ndims = get_num_dims(out_unit%diag_id, i)
   dim_lengths(1:ndims) = get_dim_lengths(out_unit%diag_id, i)
   dim_lengths(ndims + 1) = 1 ! copy
   dim_lengths(ndims + 2) = 1 ! time

   start_point(1:ndims) = 1
   start_point(ndims + 1) = copyindex ! copy
   start_point(ndims + 2) = timeindex ! time

   ret = nf90_inq_varid(out_unit%ncid, get_variable_name(out_unit%diag_id, i), var_id)
   call nc_check(ret, 'dart_nc_write_model_vars', 'getting variable id')

   ret = nf90_put_var(out_unit%ncid, var_id, model_state(start_index:end_index), &
                count=dim_lengths(1:ndims+2), start=start_point(1:ndims+2))
   call nc_check(ret, 'dart_nc_write_model_vars', 'writing')


enddo

end subroutine dart_nc_write_model_vars


!-------------------------------------------------------------------------------
!> Called if the model_mod is NOT going to write the state variables to
!> the diagnostic file.
!> This routine defines the state variables in the diagFile
!> Time and copy dimensions are already defined by init_diag_output
!> State variables are defined:
!>   variable(dim1, dim2, ...,  copy, time)
!> If there are multiple domains the variables and dimensions are
!> given the suffix _d0*, where * is the domain number.


subroutine dart_nc_write_model_atts(diagFile)

type(netcdf_file_type), intent(inout) :: diagFile

integer :: diag_id ! local variable
integer :: copy_dimId, time_dimId
integer :: ret ! netcdf return code
integer :: dummy
integer :: dimids(NF90_MAX_VAR_DIMS)
integer :: ndims
integer :: xtype ! precision for netcdf variable
integer :: i, j ! loop variables
integer :: new_varid

diagFile%diag_id = create_diagnostic_structure()
diag_id = diagFile%diag_id

if(my_task_id()==0) then

   if (r8 == digits12) then
      xtype = nf90_double
   else
      xtype = nf90_real
   endif

   ret = nf90_inq_dimid(diagFile%ncid,'copy',dimid=copy_dimId)
   call nc_check(ret, 'dart_nc_write_model_atts', 'inq_dimid copy')

   ret = nf90_inq_dimid(diagFile%ncid,'time',dimid=time_dimId)
   call nc_check(ret, 'dart_nc_write_model_atts', 'inq_dimid time')

   ! Enter define mode
   ret = nf90_Redef(diagFile%ncid)
   call nc_check(ret, 'dart_nc_write_model_atts', 'redef')

   ! Define dimensions for state
   do i = 1, get_num_variables(diag_id)

      ndims = get_num_dims(diag_id, i)

      do j = 1, ndims
         ret = nf90_def_dim(diagFile%ncid, get_dim_name(diag_id, i, j), get_dim_length(diag_id, i, j), dummy)
         !>@todo if we already have a unique names we can take this test out
         if(ret /= NF90_NOERR .and. ret /= NF90_ENAMEINUSE) then
            call nc_check(ret, 'dart_nc_write_model_atts', 'defining dimensions')
         endif
      enddo

      ! Define variables
      ! query the dimension ids
      do j = 1, ndims
         ret = nf90_inq_dimid(diagFile%ncid, get_dim_name(diag_id, i, j), dimids(j))
         call nc_check(ret, 'dart_nc_write_model_vars', 'querying dimensions')
      enddo

      dimids(ndims + 1) = copy_dimId
      dimids(ndims + 2) = time_dimId

      ret = nf90_def_var(diagFile%ncid, trim(get_variable_name(diag_id, i)), &
                        xtype=xtype, dimids=dimids(1:ndims +2), &
                        varid=new_varid)
      call nc_check(ret, 'dart_nc_write_model_atts', 'defining variable')
      call set_var_id(diag_id, i, new_varid)

   enddo

! Leave define mode
ret = nf90_enddef(diagFile%ncid)
call nc_check(ret, 'nc_write_model_atts', 'enddef')


endif

end subroutine dart_nc_write_model_atts

!-------------------------------------------------------------------------------
!>


function finalize_diag_output(ncFileID) result(ierr)

type(netcdf_file_type), intent(inout) :: ncFileID
integer             :: ierr

if (.not. module_initialized) call init_state_space_diag()

ierr = 0

if (my_task_id()==0) then
   ierr = NF90_close(ncFileID%ncid)
   if(associated(ncFileID%rtimes)) deallocate(ncFileID%rtimes, ncFileID%times )
endif

call end_diagnostic_structure()

ncFileID%fname     = "notinuse"
ncFileID%ncid      = -1
ncFileID%Ntimes    = -1
ncFileID%NtimesMax = -1

end function finalize_diag_output


!-------------------------------------------------------------------------------
! Routines that were in assim_model_mod.
!-------------------------------------------------------------------------------
!> Creates a diagnostic file(s).
!> Calls the model for any model specific attributes to be written
!> Leaves the diagnostic file open and passes out a handle: ncFileID (netcdf_file_type)


function init_diag_output(FileName, global_meta_data, &
                  copies_of_field_per_time, meta_data_per_copy, lagID) result(ncFileID)
! Typical sequence:
! NF90_OPEN             ! create netCDF dataset: enter define mode
!    NF90_def_dim       ! define dimenstions: from name and length
!    NF90_def_var       ! define variables: from name, type, and dims
!    NF90_put_att       ! assign attribute values
! NF90_ENDDEF           ! end definitions: leave define mode
!    NF90_put_var       ! provide values for variable
! NF90_CLOSE            ! close: save updated netCDF dataset
!
! Time is a funny beast ... 
! Many packages decode the time:units attribute to convert the offset to a calendar
! date/time format. Using an offset simplifies many operations, but is not the
! way we like to see stuff plotted. The "approved" calendars are:
! gregorian or standard 
!      Mixed Gregorian/Julian calendar as defined by Udunits. This is the default. 
!  noleap   Modern calendar without leap years, i.e., all years are 365 days long. 
!  360_day  All years are 360 days divided into 30 day months. 
!  julian   Julian calendar. 
!  none     No calendar. 
!
! location is another one ...
!

character(len=*), intent(in) :: FileName, global_meta_data
integer,          intent(in) :: copies_of_field_per_time
character(len=*), intent(in) :: meta_data_per_copy(copies_of_field_per_time)
integer, OPTIONAL,intent(in) :: lagID
type(netcdf_file_type)       :: ncFileID

integer :: i, metadata_length, nlines, linelen, createmode

integer ::   MemberDimID,   MemberVarID     ! for each "copy" or ensemble member
integer ::     TimeDimID,     TimeVarID
integer :: LocationDimID
integer :: MetadataDimID, MetadataVarID
integer ::   nlinesDimID,  linelenDimID, nmlVarID
logical :: local_model_mod_will_write_state_variables

character(len=129), allocatable, dimension(:) :: textblock

if (.not. module_initialized) call init_state_space_diag()

if (my_task_id() == 0) then
   if(.not. byteSizesOK()) then
       call error_handler(E_ERR,'init_diag_output', &
      'Compiler does not support required kinds of variables.',source,revision,revdate) 
   end if
   
   metadata_length = LEN(meta_data_per_copy(1))
   
   ! NetCDF large file support
   createmode = NF90_64BIT_OFFSET
   
   ! Create the file
   ncFileID%fname = trim(adjustl(FileName))//".nc"
   call nc_check(nf90_create(path = trim(ncFileID%fname), cmode = createmode, ncid = ncFileID%ncid), &
                 'init_diag_output', 'create '//trim(ncFileID%fname))
   
   write(msgstring,*)trim(ncFileID%fname), ' is ncFileID ',ncFileID%ncid
   call error_handler(E_MSG,'init_diag_output',msgstring,source,revision,revdate)
   
   ! Define the dimensions
   call nc_check(nf90_def_dim(ncid=ncFileID%ncid, &
                 name="metadatalength", len = metadata_length,        dimid = metadataDimID), &
                 'init_diag_output', 'def_dim metadatalength '//trim(ncFileID%fname))
   
   call nc_check(nf90_def_dim(ncid=ncFileID%ncid, &
                 name="locationrank",   len = LocationDims,           dimid = LocationDimID), &
                 'init_diag_output', 'def_dim locationrank '//trim(ncFileID%fname))
   
   call nc_check(nf90_def_dim(ncid=ncFileID%ncid, &
                 name="copy",           len = copies_of_field_per_time, dimid = MemberDimID), &
                 'init_diag_output', 'def_dim copy '//trim(ncFileID%fname))
   
   call nc_check(nf90_def_dim(ncid=ncFileID%ncid, &
                 name="time",           len = nf90_unlimited,         dimid = TimeDimID), &
                 'init_diag_output', 'def_dim time '//trim(ncFileID%fname))
   
   !----------------------------------------------------------------------------
   ! Find dimensions of namelist file ... will save it as a variable.
   !----------------------------------------------------------------------------
   
   ! All DART programs require input.nml, so it is unlikely this can fail, but
   ! still check and in this case, error out if not found.
   call find_textfile_dims("input.nml", nlines, linelen)
   if (nlines <= 0 .or. linelen <= 0) then
      call error_handler(E_MSG,'init_diag_output', &
                         'cannot open/read input.nml to save in diagnostic file', &
                         source,revision,revdate)
   endif
   
   allocate(textblock(nlines))
   textblock = ''
   
   call nc_check(nf90_def_dim(ncid=ncFileID%ncid, &
                 name="NMLlinelen", len = LEN(textblock(1)), dimid = linelenDimID), &
                 'init_diag_output', 'def_dim NMLlinelen '//trim(ncFileID%fname))
   
   call nc_check(nf90_def_dim(ncid=ncFileID%ncid, &
                 name="NMLnlines", len = nlines, dimid = nlinesDimID), &
                 'init_diag_output', 'def_dim NMLnlines '//trim(ncFileID%fname))
   
   !----------------------------------------------------------------------------
   ! Write Global Attributes 
   !----------------------------------------------------------------------------
   
   call nc_check(nf90_put_att(ncFileID%ncid, NF90_GLOBAL, "title", global_meta_data), &
                 'init_diag_output', 'put_att title '//trim(ncFileID%fname))
   call nc_check(nf90_put_att(ncFileID%ncid, NF90_GLOBAL, "assim_model_source", source ), &
                 'init_diag_output', 'put_att assim_model_source '//trim(ncFileID%fname))
   call nc_check(nf90_put_att(ncFileID%ncid, NF90_GLOBAL, "assim_model_revision", revision ), &
                 'init_diag_output', 'put_att assim_model_revision '//trim(ncFileID%fname))
   call nc_check(nf90_put_att(ncFileID%ncid, NF90_GLOBAL, "assim_model_revdate", revdate ), &
                 'init_diag_output', 'put_att assim_model_revdate '//trim(ncFileID%fname))
   
   if (present(lagID)) then
      call nc_check(nf90_put_att(ncFileID%ncid, NF90_GLOBAL, "lag", lagID ), &
                    'init_diag_output', 'put_att lag '//trim(ncFileID%fname))
   
      write(*,*)'init_diag_output detected Lag is present'
   
   endif 
   
   !----------------------------------------------------------------------------
   ! Create variables and attributes.
   ! The locations are part of the model (some models have multiple grids).
   ! They are written by model_mod:nc_write_model_atts
   !----------------------------------------------------------------------------
   
   !    Copy ID
   call nc_check(nf90_def_var(ncid=ncFileID%ncid, name="copy", xtype=nf90_int, &
                 dimids=MemberDimID, varid=MemberVarID), 'init_diag_output', 'def_var copy')
   call nc_check(nf90_put_att(ncFileID%ncid, MemberVarID, "long_name", "ensemble member or copy"), &
                 'init_diag_output', 'long_name')
   call nc_check(nf90_put_att(ncFileID%ncid, MemberVarID, "units",     "nondimensional"), &
                 'init_diag_output', 'units')
   call nc_check(nf90_put_att(ncFileID%ncid, MemberVarID, "valid_range", &
                 (/ 1, copies_of_field_per_time /)), 'init_diag_output', 'put_att valid_range')
   
   
   !    Metadata for each Copy
   call nc_check(nf90_def_var(ncid=ncFileID%ncid,name="CopyMetaData", xtype=nf90_char,    &
                 dimids = (/ metadataDimID, MemberDimID /),  varid=metadataVarID), &
                 'init_diag_output', 'def_var CopyMetaData')
   call nc_check(nf90_put_att(ncFileID%ncid, metadataVarID, "long_name",       &
                 "Metadata for each copy/member"), 'init_diag_output', 'put_att long_name')
   
   !    input namelist 
   call nc_check(nf90_def_var(ncid=ncFileID%ncid,name="inputnml", xtype=nf90_char,    &
                 dimids = (/ linelenDimID, nlinesDimID /),  varid=nmlVarID), &
                 'init_diag_output', 'def_var inputnml')
   call nc_check(nf90_put_att(ncFileID%ncid, nmlVarID, "long_name",       &
                 "input.nml contents"), 'init_diag_output', 'put_att input.nml')
   
   !    Time -- the unlimited dimension
   call nc_check(nf90_def_var(ncFileID%ncid, name="time", xtype=nf90_double, dimids=TimeDimID, &
                 varid =TimeVarID), 'init_diag_output', 'def_var time' )
   i = nc_write_calendar_atts(ncFileID, TimeVarID)     ! comes from time_manager_mod
   if ( i /= 0 ) then
      write(msgstring, *)'nc_write_calendar_atts  bombed with error ', i
      call error_handler(E_MSG,'init_diag_output',msgstring,source,revision,revdate)
   endif
   
   ! Create the time "mirror" with a static length. There is another routine
   ! to increase it if need be. For now, just pick something.
   ncFileID%Ntimes    = 0
   ncFileID%NtimesMAX = 1000
   allocate(ncFileID%rtimes(ncFileID%NtimesMAX), ncFileID%times(ncFileID%NtimesMAX) )
   
   !----------------------------------------------------------------------------
   ! Leave define mode so we can fill
   !----------------------------------------------------------------------------
   
   call nc_check(nf90_enddef(ncFileID%ncid), 'init_diag_output', 'enddef '//trim(ncFileID%fname))
   
   !----------------------------------------------------------------------------
   ! Fill the coordinate variables.
   ! Write the input namelist as a netCDF variable.
   ! The time variable is filled as time progresses.
   !----------------------------------------------------------------------------
   
   call nc_check(nf90_put_var(ncFileID%ncid, MemberVarID, (/ (i,i=1,copies_of_field_per_time) /) ), &
                 'init_diag_output', 'put_var MemberVarID')
   call nc_check(nf90_put_var(ncFileID%ncid, metadataVarID, meta_data_per_copy ), &
                 'init_diag_output', 'put_var metadataVarID')
    
   call file_to_text("input.nml", textblock)
   
   call nc_check(nf90_put_var(ncFileID%ncid, nmlVarID, textblock ), &
                 'init_diag_output', 'put_var nmlVarID')
   
   deallocate(textblock)
   
   !----------------------------------------------------------------------------
   ! sync to disk, but leave open
   !----------------------------------------------------------------------------
   
   call nc_check(nf90_sync(ncFileID%ncid), 'init_diag_output', 'sync '//trim(ncFileID%fname))               
   !----------------------------------------------------------------------------
   ! Define the model-specific components
   !----------------------------------------------------------------------------
   
   i =  nc_write_model_atts( ncFileID%ncid, local_model_mod_will_write_state_variables)
   if ( i /= 0 ) then
      write(msgstring, *)'nc_write_model_atts  bombed with error ', i
      call error_handler(E_MSG,'init_diag_output',msgstring,source,revision,revdate)
   endif

   if ( .not. local_model_mod_will_write_state_variables ) then
      call dart_nc_write_model_atts(ncFileID)
   endif
   
   !----------------------------------------------------------------------------
   ! sync again, but still leave open
   !----------------------------------------------------------------------------
   
   call nc_check(nf90_sync(ncFileID%ncid), 'init_diag_output', 'sync '//trim(ncFileID%fname))               
!-------------------------------------------------------------------------------
endif

! Broadcast the value of model_mod_will_write_state_variables to every task
! This keeps track of whether the model_mod or dart code will write state_variables.
call broadcast_flag(local_model_mod_will_write_state_variables, 0)
ncFileID%model_mod_will_write_state_variables = local_model_mod_will_write_state_variables

end function init_diag_output


!-------------------------------------------------------------------------------
!> Outputs the "state" to the supplied netCDF file.
!>
!> the time, and an optional index saying which
!> copy of the metadata this state is associated with.
!>
!> ncFileID       the netCDF file identifier
!> model_time     the time associated with the state vector
!> model_state    the copy of the state vector
!> copy_index     which copy of the state vector (ensemble member ID)
!>
!> Note -- the contents of ncFileId may be modified -- the time mirror needs
!> to track the state of the netCDF file. This must be "inout".


subroutine aoutput_diagnostics(ncFileID, model_time, model_state, copy_index)

type(netcdf_file_type), intent(inout) :: ncFileID
type(time_type),   intent(in) :: model_time
real(r8),          intent(in) :: model_state(:)
integer, optional, intent(in) :: copy_index

integer :: i, timeindex, copyindex
integer :: is1,id1

if (.not. module_initialized) call init_state_space_diag()

if (.not. present(copy_index) ) then     ! we are dependent on the fact
   copyindex = 1                         ! there is a copyindex == 1
else                                     ! if the optional argument is
   copyindex = copy_index                ! not specified, we'd better
endif                                    ! have a backup plan

timeindex = nc_get_tindex(ncFileID, model_time)
if ( timeindex < 0 ) then
   call get_time(model_time,is1,id1)
   write(msgstring,*)'model time (d,s)',id1,is1,' not in ',ncFileID%fname
   write(msgstring,'(''model time (d,s) ('',i8,i5,'') is index '',i6, '' in ncFileID '',i10)') &
          id1,is1,timeindex,ncFileID%ncid
   call error_handler(E_ERR,'aoutput_diagnostics', msgstring, source, revision, revdate)
endif

   call get_time(model_time,is1,id1)
   write(msgstring,'(''model time (d,s) ('',i8,i5,'') is index '',i6, '' in ncFileID '',i10)') &
          id1,is1,timeindex,ncFileID%ncid
   call error_handler(E_DBG,'aoutput_diagnostics', msgstring, source, revision, revdate)

! model_mod:nc_write_model_vars knows nothing about assim_model_types,
! so we must pass the components.
! No need to do this anymore
if(ncFileID%model_mod_will_write_state_variables) then
   i = nc_write_model_vars(ncFileID%ncid, model_state, copyindex, timeindex)
else ! dart core code writes the diagnostic file
   call dart_nc_write_model_vars(ncFileID, model_state, copyindex, timeindex)
endif

end subroutine aoutput_diagnostics


!-------------------------------------------------------------------------------
!> We need to compare the time of the current assim_model to the
!> netcdf time coordinate variable (the unlimited dimension).
!> If they are the same, no problem ...
!> If it is earlier, we need to find the right index and insert ...
!> If it is the "future", we need to add another one ...
!> If it is in the past but does not match any we have, we're in trouble.
!> The new length of the "time" variable is returned.
!>
!> A "times" array has been added to mirror the times that are stored
!> in the netcdf time coordinate variable. While somewhat unpleasant, it
!> is SUBSTANTIALLY faster than reading the netcdf time variable at every
!> turn -- which caused a geometric or exponential increase in overall 
!> netcdf I/O. (i.e. this was really bad)
!>
!> The time mirror is maintained as a time_type, so the comparison with
!> the state time uses the operators for the time_type. The netCDF file,
!> however, has time units of a different convention. The times are
!> converted only when appending to the time coordinate variable.    


function nc_get_tindex(ncFileID, statetime) result(timeindex)

type(netcdf_file_type), intent(inout) :: ncFileID
type(time_type), intent(in) :: statetime
integer                     :: timeindex

integer  :: nDimensions, nVariables, nAttributes, unlimitedDimID, TimeVarID
integer  :: xtype, ndims, nAtts, nTlen
integer  :: secs, days, ncid, i

character(len=NF90_MAX_NAME)          :: varname
integer, dimension(NF90_MAX_VAR_DIMS) :: dimids

timeindex = -1  ! assume bad things are going to happen

ncid = ncFileID%ncid

! Make sure we're looking at the most current version of the netCDF file.
! Get the length of the (unlimited) Time Dimension 
! If there is no length -- simply append a time to the dimension and return ...
! Else   get the existing times ["days since ..."] and convert to time_type 
!        if the statetime < earliest netcdf time ... we're in trouble
!        if the statetime does not match any netcdf time ... we're in trouble
!        if the statetime > last netcdf time ... append a time ... 

call nc_check(NF90_Sync(ncid), 'nc_get_tindex', 'sync '//trim(ncFileID%fname))    
call nc_check(NF90_Inquire(ncid, nDimensions, nVariables, nAttributes, unlimitedDimID), &
              'nc_get_tindex', 'inquire '//trim(ncFileID%fname))
call nc_check(NF90_Inq_Varid(ncid, "time", TimeVarID), &
              'nc_get_tindex', 'inq_varid time '//trim(ncFileID%fname))
call nc_check(NF90_Inquire_Variable(ncid, TimeVarID, varname, xtype, ndims, dimids, nAtts), &
              'nc_get_tindex', 'inquire_variable time '//trim(ncFileID%fname))
call nc_check(NF90_Inquire_Dimension(ncid, unlimitedDimID, varname, nTlen), &
              'nc_get_tindex', 'inquire_dimension unlimited '//trim(ncFileID%fname))

! Sanity check all cases first.

if ( ndims /= 1 ) then
   write(msgstring,*)'"time" expected to be rank-1' 
   call error_handler(E_WARN,'nc_get_tindex',msgstring,source,revision,revdate)
   timeindex = timeindex -   1
endif
if ( dimids(1) /= unlimitedDimID ) then
   write(msgstring,*)'"time" must be the unlimited dimension'
   call error_handler(E_WARN,'nc_get_tindex',msgstring,source,revision,revdate)
   timeindex = timeindex -  10
endif
if ( timeindex < -1 ) then
   write(msgstring,*)'trouble deep ... can go no farther. Stopping.'
   call error_handler(E_ERR,'nc_get_tindex',msgstring,source,revision,revdate)
endif

! convert statetime to time base of "days since ..."
call get_time(statetime, secs, days)

if (ncFileID%Ntimes < 1) then          ! First attempt at writing a state ...

   write(msgstring,*)'current unlimited  dimension length',nTlen, &
                     'for ncFileID ',trim(ncFileID%fname)
   call error_handler(E_DBG,'nc_get_tindex',msgstring,source,revision,revdate)
   write(msgstring,*)'current time array dimension length',ncFileID%Ntimes
   call error_handler(E_DBG,'nc_get_tindex',msgstring,source,revision,revdate)

   nTlen = nc_append_time(ncFileID, statetime)

   write(msgstring,*)'Initial time array dimension length',ncFileID%Ntimes
   call error_handler(E_DBG,'nc_get_tindex',msgstring,source,revision,revdate)

endif


TimeLoop : do i = 1,ncFileId%Ntimes

   if ( statetime == ncFileID%times(i) ) then
      timeindex = i
      exit TimeLoop
   endif

enddo TimeLoop



if ( timeindex <= 0 ) then   ! There was no match. Either the model
                             ! time precedes the earliest file time - or - 
                             ! model time is somewhere in the middle  - or - 
                             ! model time needs to be appended.

   if (statetime < ncFileID%times(1) ) then

      call error_handler(E_MSG,'nc_get_tindex', &
              'Model time precedes earliest netCDF time.', source,revision,revdate)

      write(msgstring,*)'          model time (days, seconds) ',days,secs
      call error_handler(E_MSG,'nc_get_tindex',msgstring,source,revision,revdate)

      call get_time(ncFileID%times(1),secs,days)
      write(msgstring,*)'earliest netCDF time (days, seconds) ',days,secs
      call error_handler(E_MSG,'nc_get_tindex',msgstring,source,revision,revdate)

      call error_handler(E_ERR,'nc_get_tindex', &
              'Model time precedes earliest netCDF time.', source,revision,revdate)
      timeindex = -2

   else if ( statetime < ncFileID%times(ncFileID%Ntimes) ) then  

      ! It is somewhere in the middle without actually matching an existing time.
      ! This is very bad.

      write(msgstring,*)'model time does not match any netCDF time.'
      call error_handler(E_MSG,'nc_get_tindex',msgstring,source,revision,revdate)
      write(msgstring,*)'model time (days, seconds) is ',days,secs
      call error_handler(E_MSG,'nc_get_tindex',msgstring,source,revision,revdate)

      BadLoop : do i = 1,ncFileId%Ntimes   ! just find times to print before exiting

         if ( ncFileId%times(i) > statetime ) then
            call get_time(ncFileID%times(i-1),secs,days)
            write(msgstring,*)'preceding netCDF time (days, seconds) ',days,secs
            call error_handler(E_MSG,'nc_get_tindex',msgstring,source,revision,revdate)

            call get_time(ncFileID%times(i),secs,days)
            write(msgstring,*)'subsequent netCDF time (days, seconds) ',days,secs
            call error_handler(E_ERR,'nc_get_tindex',msgstring,source,revision,revdate)
            timeindex = -3
            exit BadLoop
         endif

      enddo BadLoop

   else ! we must need to append ... 

      timeindex = nc_append_time(ncFileID, statetime)

      write(msgstring,'(''appending model time (d,s) ('',i8,i5,'') as index '',i6, '' in ncFileID '',i10)') &
          days,secs,timeindex,ncid
      call error_handler(E_DBG,'nc_get_tindex',msgstring,source,revision,revdate)

   endif
   
endif

end function nc_get_tindex


!-------------------------------------------------------------------------------
!> Initializes a model state diagnostic file for input. A file id is
!> returned which for now is just an integer unit number.
!>@todo ONLY USED BY RMS_DIAG - can we remove this?
!>        YES we agreed this can be removed JPH, TJH & NSC


function init_diag_input(file_name, global_meta_data, model_size, copies_of_field_per_time)

integer :: init_diag_input, io
character(len=*), intent(in)  :: file_name
character(len=*), intent(out) :: global_meta_data
integer,            intent(out) :: model_size, copies_of_field_per_time

if (.not. module_initialized) call init_state_space_diag()

init_diag_input = get_unit()
open(unit = init_diag_input, file = file_name, action = 'read', iostat = io)
if (io /= 0) then
   write(msgstring,*) 'unable to open diag input file ', trim(file_name), ' for reading'
   call error_handler(E_ERR,'init_diag_input',msgstring,source,revision,revdate)
endif

! Read meta data
read(init_diag_input, *, iostat = io) global_meta_data
if (io /= 0) then
   write(msgstring,*) 'unable to read expected character string from diag input file ', &
                       trim(file_name), ' for global_meta_data'
   call error_handler(E_ERR,'init_diag_input',msgstring,source,revision,revdate)
endif

! Read the model size
read(init_diag_input, *, iostat = io) model_size
if (io /= 0) then
   write(msgstring,*) 'unable to read expected integer from diag input file ', &
                       trim(file_name), ' for model_size'
   call error_handler(E_ERR,'init_diag_input',msgstring,source,revision,revdate)
endif

! Read the number of copies of field per time
read(init_diag_input, *, iostat = io) copies_of_field_per_time
if (io /= 0) then
   write(msgstring,*) 'unable to read expected integer from diag input file ', &
                       trim(file_name), ' for copies_of_field_per_time'
   call error_handler(E_ERR,'init_diag_input',msgstring,source,revision,revdate)
endif

end function init_diag_input


!-------------------------------------------------------------------------------
!> The current time is appended to the "time" coordinate variable.
!> The new length of the "time" variable is returned.
!>
!> This REQUIRES that "time" is a coordinate variable AND it is the
!> unlimited dimension. If not ... bad things happen.


function nc_append_time(ncFileID, time) result(lngth)

type(netcdf_file_type), intent(inout) :: ncFileID
type(time_type), intent(in) :: time
integer                     :: lngth

integer  :: nDimensions, nVariables, nAttributes, unlimitedDimID
integer  :: TimeVarID
integer  :: secs, days, ncid
real(digits12) :: realtime         ! gets promoted to nf90_double ...

character(len=NF90_MAX_NAME)          :: varname
integer                               :: xtype, ndims, nAtts
integer, dimension(NF90_MAX_VAR_DIMS) :: dimids

type(time_type), allocatable, dimension(:) :: temptime   ! only to reallocate mirror
real(digits12),  allocatable, dimension(:) :: tempRtime  ! only to reallocate mirror

lngth = -1 ! assume a bad termination

ncid = ncFileID%ncid

call nc_check(NF90_Inquire(ncid, nDimensions, nVariables, nAttributes, unlimitedDimID), &
              'nc_append_time', 'inquire '//ncFileID%fname)
call nc_check(NF90_Inq_Varid(ncid, "time", TimeVarID), 'nc_append_time', 'inq_varid time')
call nc_check(NF90_Inquire_Variable(ncid, TimeVarID, varname, xtype, ndims, dimids, nAtts), &
             'nc_append_time', 'inquire_variable time')

if ( ndims /= 1 ) call error_handler(E_ERR,'nc_append_time', &
           '"time" expected to be rank-1',source,revision,revdate)

if ( dimids(1) /= unlimitedDimID ) call error_handler(E_ERR,'nc_append_time', &
           'unlimited dimension expected to be slowest-moving',source,revision,revdate)

! make sure the mirror and the netcdf file are in sync
call nc_check(NF90_Inquire_Dimension(ncid, unlimitedDimID, varname, lngth ), &
           'nc_append_time', 'inquire_dimension unlimited')

if (lngth /= ncFileId%Ntimes) then
   write(msgstring,*)'netCDF file has length ',lngth,' /= mirror has length of ',ncFileId%Ntimes
   call error_handler(E_ERR,'nc_append_time', &
           'time mirror and netcdf file time dimension out-of-sync', &
           source,revision,revdate,text2=msgstring)
endif

! make sure the time mirror can handle another entry.
if ( lngth == ncFileID%NtimesMAX ) then   

   write(msgstring,*)'doubling mirror length of ',lngth,' of ',ncFileID%fname
   call error_handler(E_DBG,'nc_append_time',msgstring,source,revision,revdate)

   allocate(temptime(ncFileID%NtimesMAX), tempRtime(ncFileID%NtimesMAX)) 
   temptime   = ncFileID%times            ! preserve
   tempRtime = ncFileID%rtimes            ! preserve

   deallocate(ncFileID%times, ncFileID%rtimes)

   ncFileID%NtimesMAX = 2 * ncFileID%NtimesMAX  ! double length of exising arrays

   allocate(ncFileID%times(ncFileID%NtimesMAX), ncFileID%rtimes(ncFileID%NtimesMAX) )

   ncFileID%times(1:lngth)  = temptime    ! reinstate
   ncFileID%rtimes(1:lngth) = tempRtime   ! reinstate

   deallocate(temptime, tempRtime)

endif

call get_time(time, secs, days)         ! get time components to append
realtime = days + secs/86400.0_digits12 ! time base is "days since ..."
lngth           = lngth + 1             ! index of new time 
ncFileID%Ntimes = lngth                 ! new working length of time mirror

call nc_check(nf90_put_var(ncid, TimeVarID, realtime, start=(/ lngth /) ), &
           'nc_append_time', 'put_var time')

ncFileID%times( lngth) = time
ncFileID%rtimes(lngth) = realtime

write(msgstring,*)'ncFileID (',ncid,') : ',trim(adjustl(varname)), &
         ' (should be "time") has length ',lngth, ' appending t= ',realtime
call error_handler(E_DBG,'nc_append_time',msgstring,source,revision,revdate)

end function nc_append_time


!-------------------------------------------------------------------------------
!> routine to be closer to CF convention


function nc_write_calendar_atts(ncFileID, TimeVarID) result(ierr)

type(netcdf_file_type), intent(in) :: ncFileID
integer,                intent(in) :: TimeVarID
integer                            :: ierr

integer :: ncid

ierr = 0

ncid = ncFileID%ncid

call nc_check(nf90_put_att(ncid, TimeVarID, "long_name", "time"), &
              'nc_write_calendar_atts', 'put_att long_name '//trim(ncFileID%fname))
call nc_check(nf90_put_att(ncid, TimeVarID, "axis", "T"), &
              'nc_write_calendar_atts', 'put_att axis '//trim(ncFileID%fname))
call nc_check(nf90_put_att(ncid, TimeVarID, "cartesian_axis", "T"), &
              'nc_write_calendar_atts', 'put_att cartesian_axis '//trim(ncFileID%fname))

select case( get_calendar_type() )
case(THIRTY_DAY_MONTHS)
!  call get_date_thirty(time, year, month, day, hour, minute, second)
case(GREGORIAN)
   call nc_check(nf90_put_att(ncid, TimeVarID, "calendar", "gregorian" ), &
              'nc_write_calendar_atts', 'put_att calendar '//trim(ncFileID%fname))
   call nc_check(nf90_put_att(ncid, TimeVarID, "units", "days since 1601-01-01 00:00:00"), &
              'nc_write_calendar_atts', 'put_att units '//trim(ncFileID%fname))
case(JULIAN)
   call nc_check(nf90_put_att(ncid, TimeVarID, "calendar", "julian" ), &
              'nc_write_calendar_atts', 'put_att calendar '//trim(ncFileID%fname))
case(NOLEAP)
   call nc_check(nf90_put_att(ncid, TimeVarID, "calendar", "no_leap" ), &
              'nc_write_calendar_atts', 'put_att calendar '//trim(ncFileID%fname))
case default
   call nc_check(nf90_put_att(ncid, TimeVarID, "calendar", "no calendar" ), &
              'nc_write_calendar_atts', 'put_att calendar '//trim(ncFileID%fname))
   call nc_check(nf90_put_att(ncid, TimeVarID, "units", "days since 0000-00-00 00:00:00"), &
              'nc_write_calendar_atts', 'put_att units '//trim(ncFileID%fname))
end select

end function nc_write_calendar_atts


!-------------------------------------------------------------------------------
!> Returns the meta data associated with each copy of data in
!> a diagnostic input file. Should be called immediately after 
!> function init_diag_input.
!>@todo This is only used by the program rms_diag.f90 - can we just remove this?
!>        YES we agreed this can be removed JPH, TJH & NSC

subroutine get_diag_input_copy_meta_data(file_id, model_size_out, num_copies, &
   location, meta_data_per_copy)

integer, intent(in) :: file_id, model_size_out, num_copies
type(location_type), intent(out) :: location(model_size_out)
character(len=*) :: meta_data_per_copy(num_copies)

character(len=129) :: header
integer :: i, j, io

! Should have space checks, etc here
! Read the meta data associated with each copy
do i = 1, num_copies
   read(file_id, *, iostat = io) j, meta_data_per_copy(i)
   if (io /= 0) then
      write(msgstring,*) 'error reading metadata for copy ', i, ' from diag file'
      call error_handler(E_ERR,'get_diag_input_copy_meta_data', &
                         msgstring,source,revision,revdate)
   endif
end do

! Will need other metadata, too; Could be as simple as writing locations
read(file_id, *, iostat = io) header
if (io /= 0) then
   write(msgstring,*) 'error reading header from diag file'
   call error_handler(E_ERR,'get_diag_input_copy_meta_data', &
                      msgstring,source,revision,revdate)
endif
if(header /= 'locat') then
   write(msgstring,*)'expected to read "locat" got ',trim(adjustl(header))
   call error_handler(E_ERR,'get_diag_input_copy_meta_data', &
                      msgstring, source, revision, revdate)
endif

! Read in the locations
do i = 1, model_size_out
   location(i) =  read_location(file_id)
end do

end subroutine get_diag_input_copy_meta_data

!> @}
end module state_space_diag_mod

! <next few lines under version control, do not edit>
! $URL$
! $Id$
! $Revision$
! $Date$
