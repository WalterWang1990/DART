! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!
! $Id$

module model_mod

! This is the interface between the model CM1 and DART.

! Modules that are absolutely required for use are listed
use        types_mod, only : r4, r8, digits12, i8, SECPERDAY, MISSING_R8,      &
                             MISSING_I, rad2deg, deg2rad, PI
use time_manager_mod, only : time_type, set_time, set_date, get_date, get_time,&
                             print_time, print_date, set_calendar_type,        &
                             operator(*),  operator(+), operator(-),           &
                             operator(>),  operator(<), operator(/),           &
                             operator(/=), operator(<=)

use     location_mod, only : location_type, get_dist, query_location,          &
                             get_close_maxdist_init, get_close_type,           &
                             set_location, get_location,                       & 
                             get_close_obs_init, write_location,               &
                             loc_get_close_obs => get_close_obs, set_periodic  

use    utilities_mod, only : register_module, error_handler,                   &
                             E_ERR, E_WARN, E_MSG, logfileunit, get_unit,      &
                             nc_check, do_output, to_upper,                    &
                             find_namelist_in_file, check_namelist_read,       &
                             open_file, file_exist, find_textfile_dims,        &
                             file_to_text, close_file, do_nml_file,            &
                             do_nml_term, string_to_real, string_to_logical

use     obs_kind_mod, only : get_raw_obs_kind_index,  &
                             get_raw_obs_kind_name

use mpi_utilities_mod, only : my_task_id

use    random_seq_mod, only : random_seq_type, init_random_seq, random_gaussian

use distributed_state_mod, only : get_state

use state_structure_mod,   only : add_domain, get_model_variable_indices, &
                                  get_domain_size, state_structure_info,  &
                                  get_dart_vector_index,  &
                                  get_num_dims, get_dim_name, get_variable_name, &
                                  get_kind_index, get_dim_length,            &
                                  get_varid_from_kind,                      &
                                  get_num_variables,  &
                                  get_num_dims

use ensemble_manager_mod, only : ensemble_type, copies_in_window

use dart_time_io_mod, only : write_model_time

use typesizes
use netcdf 

implicit none
private

! these routines must be public and you cannot change
! the arguments - they will be called *from* the DART code.
public :: static_init_model,             &
          get_model_size,                &
          adv_1step,                     &
          get_state_meta_data,           &
          model_interpolate,             &
          get_model_time_step,           &
          end_model,                     &
          init_time,                     &
          init_conditions,               &
          nc_write_model_atts,           &
          nc_write_model_vars,           &
          pert_model_copies,             &
          get_close_maxdist_init,        &
          get_close_obs_init,            &
          get_close_obs,                 &
          query_vert_localization_coord, &
          vert_convert,                  &
          read_model_time,               &
          write_model_time


! version controlled file description for error handling, do not edit
character(len=256), parameter :: source   = &
   "$URL$"
character(len=32 ), parameter :: revision = "$Revision$"
character(len=128), parameter :: revdate  = "$Date$"

character(len=512) :: string1, string2
logical, save :: module_initialized = .false.

! Storage for a random sequence for perturbing a single initial state

type(random_seq_type) :: random_seq

! things which can/should be in the model_nml

integer            :: assimilation_period_days = 0
integer            :: assimilation_period_seconds = 21600
real(r8)           :: model_perturbation_amplitude = 0.2
logical            :: output_state_vector = .true.
integer            :: debug = 0   ! turn up for more and more debug messages
character(len=32)  :: calendar = 'Gregorian'
character(len=512) :: cm1_template_file = 'null'
logical            :: periodic_x = .true.
logical            :: periodic_y = .true.
logical            :: periodic_z = .false. ! not supported at the moment

!  The DART state vector may consist of things like:  
!
! float prs(nk, nj, ni) ;
!         prs:long_name = "pressure" ;
!         prs:units = "Pa" ;
! float ua(nk, nj, nip1) ;
!         ua:long_name = "west-east velocity (at u points)" ;
!         ua:units = "m/s" ;
! float va(nk, njp1, ni) ;
!         va:long_name = "south-north velocity (at v points)" ;
!         va:units = "m/s" ;
! float wa(nkp1, nj, ni) ;
!         wa:long_name = "vertical velocity (at w points)" ;
!         wa:units = "m/s" ;
! float ppi(nk, nj, ni) ;
!         ppi:long_name = "perturbation non-dimensional pressure" ;
!         ppi:units = "nondimensional" ;
! float tha(nk, nj, ni) ;
!         tha:long_name = "perturbation potential temperature" ;
!         tha:units = "K" ;
! float ppx(nk, nj, ni) ;
!         ppx:long_name = "change in nondimensional pressure used for forward-time-weighting on small steps" ;
!         ppx:units = "nondimensional" ;

! DART state vector contents are specified in the input.nml:&model_nml namelist.
integer, parameter :: max_state_variables = 80
integer, parameter :: num_state_table_columns = 5
character(len=NF90_MAX_NAME) :: model_variables(MAX_STATE_VARIABLES * num_state_table_columns ) = ' '
character(len=NF90_MAX_NAME) :: var_names(MAX_STATE_VARIABLES) = ' '
logical  ::                   update_list(MAX_STATE_VARIABLES) = .FALSE.
integer  ::                     kind_list(MAX_STATE_VARIABLES) = MISSING_I
real(r8) ::                    clamp_vals(MAX_STATE_VARIABLES,2) = MISSING_R8


! indices associated with variable_table columns
integer, parameter :: VT_VARNAME_INDEX  = 1
integer, parameter :: VT_DARTKIND_INDEX = 2
integer, parameter :: VT_UPDATE_INDEX   = 3
integer, parameter :: VT_MINVAL_INDEX   = 4
integer, parameter :: VT_MAXVAL_INDEX   = 5

namelist /model_nml/  &
   output_state_vector,         &
   assimilation_period_days,    &  ! for now, this is the timestep
   assimilation_period_seconds, &
   model_perturbation_amplitude,&
   cm1_template_file,           & 
   calendar,                    &
   debug,                       &
   model_variables,             &
   periodic_x,                  & ! FIXME: should we grab this information from namelist.input
   periodic_y,                  & ! or have this information written as attributes to restart files?
   periodic_z

integer :: nfields
integer :: domid


! grid sizes - should be x,y,z
! scalar grid: i,j,k (1 scalar grid)
! vector grids: i+1, j+1, k+1 (3 vector grids)
! Also have 2d fields on scalar grid (should these be treated separately).
integer  :: ni  =-1, nj  =-1, nk  =-1   ! scalar grid counts
integer  :: nip1=-1, njp1=-1, nkp1=-1 ! staggered grid counts 

! Arrays of grid values

! scalar grid positions
real(r8), allocatable :: xh(:)   ! west-east scalar cells
real(r8), allocatable :: yh(:)   ! south-north scalar cells
real(r8), allocatable :: zh(:)   ! normal height of scalar cells

! staggered grid positions
real(r8), allocatable :: xf(:)   ! west-east staggered cells
real(r8), allocatable :: yf(:)   ! south-north staggered cells
real(r8), allocatable :: zf(:)   ! normal height of staggered cells

! terriain height
real(r8), allocatable :: zs(:,:) ! terrain height

real(r8), allocatable :: axis(:) ! this array is the length of largest axis

! full grid points
real(r8), allocatable :: zfull(:,:,:) ! height full (w) grid points (3d array) 
real(r8), allocatable :: zhalf(:,:,:) ! height half (scalar) grid points (3d array) 

! logicals to store what grid a variable is on
logical, allocatable :: on_ugrid(:), on_vgrid(:), on_z_full(:)

integer               :: model_size      ! the state vector length
type(time_type)       :: model_timestep  ! smallest time to adv model

! use fortran intrinsic reshape() instead of loops, when possible.
! works on all ranks (so no overloading needed) and is compact.

contains

!==================================================================
! REQUIRED interfaces. the names and arguments cannot be changed 
!    because these are called by DART routines.

!------------------------------------------------------------------
! Called to do one time initialization of the model.
! Must set the time step, model size, and read in and save
! the grid size and lat/lon information.  also the number
! and fields in the state vector.

subroutine static_init_model()

! FIXME:
! Local variables - all the important ones have module scope

integer :: ncid
integer :: iunit, io, i
integer :: ss, dd
integer :: d ! loop variable
integer :: n ! number of variables in the state
character(len=NF90_MAX_NAME) :: dimname


if ( module_initialized ) return ! only need to do this once.

! Print module information to log file and stdout.
call register_module(source, revision, revdate)

! Set this flag early so we can call other routines without
! them trying to call back into this routine.  but do that
! with care - because anything you call must not depend on
! something that isn't set yet.  (safest implementation would
! be if this is called a second time to error out instead of
! returning silently.)

module_initialized = .true.

! Read the DART namelist for this model
call find_namelist_in_file('input.nml', 'model_nml', iunit)
read(iunit, nml = model_nml, iostat = io)
call check_namelist_read(iunit, io, 'model_nml')

! Record the namelist values used for the run
if (do_nml_file()) write(logfileunit, nml=model_nml)
if (do_nml_term()) write(     *     , nml=model_nml)

if ( periodic_z ) then
   write(string1,*)'periodic_z is not supported'
   call error_handler(E_ERR,'static_init_model',string1,source,revision,revdate)
endif

call nc_check( nf90_open(trim(cm1_template_file), NF90_NOWRITE, ncid), &
                  'static_init_model', 'open '//trim(cm1_template_file))

! 1) get grid dimensions
! 2) allocate space for the grid
! 3) read it from the template file
 
call get_grid_info(ncid)

if((debug > 0) .and. do_output()) then
   write(string1,'("static    grid: ni,   nj,   nk   =",3(1x,i5))')  ni, nj, nk
   call say(string1)
   write(string1,'("staggered grid: nip1, njp1, nkp1 =",3(1x,i5))') nip1, njp1, nkp1
   call say(string1)
endif
 
! reads in staggered and scalar grid arrays
call get_grid(ncid)

! set periodic boundary conditions for x and y
if (periodic_x) call set_periodic('x', xf(1), xf(nip1))
if (periodic_y) call set_periodic('y', yf(1), yf(njp1))

call nc_check( nf90_close(ncid), &
                  'static_init_model', 'close '//trim(cm1_template_file))

! HK This comment block implies that model_mod is taking care of this
! Really everything is done in state_structure_mod.
! Compile the list of model variables to use in the creation
! of the DART state vector. Required to determine model_size.
!
! Verify all variables are in the model analysis file
!
! Compute the offsets into the state vector for the start of each
! different variable type. Requires reading shapes from the model
! analysis file. As long as TIME is the LAST dimension, we're OK.
!
! Record the extent of the data type in the state vector.

! fill in the global arrays that store the variable names, min/max, etc

call parse_variable_input( model_variables, nfields )

! determine variable shapes for the state structure

domid = add_domain(cm1_template_file, nfields, &
                   var_names, kind_list, clamp_vals, update_list )

! print information in the state structure

if ((debug > 0) .and. do_output()) call state_structure_info(domid)

model_size = get_domain_size(domid)

if ((debug > 0) .and. do_output()) then
  write(string1, *)'static_init_model: model_size = ', model_size
  call say(string1)
endif
 
call set_calendar_type( calendar )   ! comes from model_mod_nml

model_timestep = set_model_time_step()
 
if ((debug > 0) .and. do_output()) then
   call get_time(model_timestep,ss,dd) ! set_time() assures the seconds [0,86400)
   write(string1,*)'assimilation period is ',dd,' days ',ss,' seconds'
   call error_handler(E_MSG,'static_init_model',string1,source,revision,revdate)
endif

! Array to store an axis. Used in model_interpolate
allocate(axis(MAXVAL((/ni, nip1, nj, njp1, nk, nkp1/))))

! Grid from variable id
n = get_num_variables(domid)

allocate(on_z_full(n))
allocate(on_ugrid(n))
allocate(on_vgrid(n))


on_ugrid = .false.
on_vgrid = .false.
on_z_full = .false.

do i = 1, get_num_variables(domid)

   do d = 1, get_num_dims(domid, i)
      dimname = get_dim_name(domid, i, d)

      select case (dimname)
         case ('nip1')
            on_ugrid(i) = .true.
         case ('njp1')
            on_vgrid(i) = .true.
         case ('nkp1')
            on_z_full(i) = .true.
      end select
   enddo

enddo


end subroutine static_init_model

!------------------------------------------------------------------

! Returns the size of the model as an integer. 
! this version assumes that static_init_model has computed the count
! and put it in the module global 'model_size'

function get_model_size()

integer :: get_model_size

if ( .not. module_initialized ) call static_init_model()

get_model_size = model_size

end function get_model_size


!------------------------------------------------------------------

! i'm assuming that we can't call CM1 as a subroutine.  if that's not
! correct we can fill this in.  otherwise it's an error to try it.

subroutine adv_1step(x, time)

real(r8),        intent(inout) :: x(:)
type(time_type), intent(in)    :: time

if ( .not. module_initialized ) call static_init_model()

if (do_output()) then
   call print_time(time,'adv_1step called with DART time of')
   call print_time(time,'adv_1step called with DART time of', logfileunit)
endif

call error_handler(E_ERR, 'adv_1step', &
   'Cannot advance CM1 with a subroutine call; async cannot equal 0', &
   source,revision,revdate)

end subroutine adv_1step


!------------------------------------------------------------------

! given an index into the state vector, return its location and
! if given, the var kind.   despite the name, var_type is a generic
! kind, like those in obs_kind/obs_kind_mod.f90, starting with KIND_

subroutine get_state_meta_data(state_ens_handle, index_in, location, var_type)

type(ensemble_type), intent(in)  :: state_ens_handle
integer(i8),         intent(in)  :: index_in
type(location_type), intent(out) :: location
integer, optional,   intent(out) :: var_type
  
! Local variables

integer :: x_index, y_index, z_index
integer :: var_id
real(r8) :: xlocation, ylocation, zlocation

if ( .not. module_initialized ) call static_init_model()

! get the local indicies and type from dart index. 
call get_model_variable_indices(index_in, x_index, y_index, z_index, var_id=var_id)

xlocation = 0.0_r8
ylocation = 0.0_r8
zlocation = 0.0_r8

if (on_vgrid(var_id)) then

   xlocation = xh(x_index)
   ylocation = yf(y_index)

   if (y_index == 1 .or. y_index > nj ) then ! off height grid

      if (periodic_y) then ! 0 = end, interpolate between first and last

         zlocation = 0.5*get_my_z(var_id, x_index, 1, z_index) + 0.5*get_my_z(var_id, x_index, nj, z_index)

      else ! extrapolate

         if (y_index == 1) then ! below s grid
            zlocation = extrapolate(yh(1), yh(2), get_my_z(var_id, x_index, 1, z_index), get_my_z(var_id, x_index, 2, z_index), yf(y_index))
         else ! above s grid
            zlocation = extrapolate(yh(nj-1), yh(nj), get_my_z(var_id, x_index, nj-1, z_index), get_my_z(var_id, x_index, nj, z_index), yf(y_index))
         endif

      endif

   else ! within height grid, interpolate

      zlocation = 0.5*get_my_z(var_id, x_index, y_index, z_index) + 0.5*get_my_z(var_id, x_index, y_index -1, z_index)

   endif

elseif (on_ugrid(var_id)) then

   xlocation = xf(x_index)
   ylocation = yh(y_index)

   if (x_index == 1  .or. x_index > ni ) then ! off height grid

      if (periodic_x) then ! 0 = end, interpolate between first and last

         zlocation = 0.5*get_my_z(var_id, 1, y_index, z_index) + 0.5*get_my_z(var_id, ni, y_index, z_index)

      else ! extrapolate

         if (y_index == 1) then ! left of s grid
            zlocation = extrapolate(xh(1), xh(2), get_my_z(var_id, 1, y_index, z_index), get_my_z(var_id, 2, y_index, z_index), xf(Y_index))
         else ! right of s grid
            zlocation = extrapolate(xh(ni-1), xh(ni), get_my_z(var_id, ni-1, y_index, z_index), get_my_z(var_id, ni, y_index, z_index), xf(Y_index))
         endif

      endif

   else ! within height grid, interpolate

      zlocation = 0.5*get_my_z(var_id, x_index, y_index, z_index) + 0.5*get_my_z(var_id, x_index -1, y_index, z_index)

   endif

else ! on sgrid

   xlocation = xh(x_index)
   ylocation = yh(y_index)
   zlocation = get_my_z(var_id, x_index, y_index, z_index)

endif


location = set_location(xlocation, ylocation, zlocation)
 
if (present(var_type)) then
   var_type = get_kind_index(domid, var_id)
endif

end subroutine get_state_meta_data

!------------------------------------------------------------------
! Extrapolate height from s points to u/v points at the edge of the 
! grid. Used when the grid is not periodic.
! Doing a linear extrapolation
function extrapolate(x1, x2, z1, z2, x)

real(r8), intent(in) :: x1, x2 ! x (or y) values at 2 points
real(r8), intent(in) :: z1, z2 ! z values at two points
real(r8), intent(in) :: x ! location to extrapolate to

real(r8) :: extrapolate

! x* is the location to extrapolate to.
! z* is height at x*
! Using
! z* = z_k-1 + ((x_* - x_k-1)/(x_k - x_k-1))*(z_k - z_k-1)
! z* = z1    + ((x*  - x1)/(x2 - x1))*(z2 - z1)

extrapolate = z1 + ((x - x1) / (x2 - x1)) *(z2 - z1)

!extrapolate = z1 + 0.5*(z2 -z1) ! can we use the indices?

end function extrapolate

!------------------------------------------------------------------
! Return zfull or zhalf at index i,j,k depending on whether
! the variable is on zfull or zhalf.
function get_my_z(varid, i, j, k)

integer, intent(in) :: varid ! this is the variable order in the state
integer, intent(in) :: i, j, k ! indicies into z grid
real(r8) :: get_my_z

if (on_z_full(varid)) then
   get_my_z = zfull(i, j, k)
else ! on zhalf
   get_my_z = zhalf(i, j, k)
endif

end function

!------------------------------------------------------------------


! Returns the external time step of the model; the smallest increment
! in time that the model is capable of advancing the state in a given
! implementation. This interface is required for all applications.
! this implementation assumes that static_init_model() will set a
! module global variable before returning.
! THIS IS NOT RELATED TO THE INTERNAL TIMESTEP OF THE MODEL.

function get_model_time_step()

type(time_type) :: get_model_time_step

if ( .not. module_initialized ) call static_init_model()

get_model_time_step = model_timestep

end function get_model_time_step



!------------------------------------------------------------------

! called once at the end of a run

subroutine end_model()

deallocate( xh, yh, zh ) ! deallocate half grid points
deallocate( xf, yf, zf ) ! deallocate full grid points
deallocate( zs, zhalf, zfull ) ! deallocate terrain values
              
end subroutine end_model


!------------------------------------------------------------------

! only useful if there is a pre-defined set of initial conditions
! that isn't read from a file.  i'm assuming that is not true for CM1,
! so make it an error to call this routine. 

! return an initial time for the case when there is no restart file
! that contains a real model time.

! At present, this is only used if the namelist parameter 
! start_from_restart is set to .false. in the program perfect_model_obs.
! If this option is not to be used in perfect_model_obs, or if no 
! synthetic data experiments using perfect_model_obs are planned, 
! this can be a NULL INTERFACE.

subroutine init_time(time)

type(time_type), intent(out) :: time

if ( .not. module_initialized ) call static_init_model()

! example of how to set the time to seconds=0, days=0:
time = set_time(0,0)

call error_handler(E_ERR, 'init_time', &
   'Cannot start CM1 without a restart file; start_from_restart cannot be .false. in PMO', &
   source,revision,revdate)

end subroutine init_time


!------------------------------------------------------------------

! only useful if there is a pre-defined set of initial conditions
! that isn't read from a file.  i'm assuming that is not true for CM1,
! so make it an error to call this routine. 

! Returns a model state vector, x, that is some sort of appropriate
! initial condition for starting up a long integration of the model.

! At present, this is only used if the namelist parameter 
! start_from_restart is set to .false. in the program perfect_model_obs.
! If this option is not to be used in perfect_model_obs, or if no 
! synthetic data experiments using perfect_model_obs are planned, 
! this can be a NULL INTERFACE.

subroutine init_conditions(x)

real(r8), intent(out) :: x(:)

if ( .not. module_initialized ) call static_init_model()
 
! example of how to set the state vector to all 0s:
x = 0.0_r8

call error_handler(E_ERR, 'init_conditions', &
   'Cannot start CM1 without a restart file; start_from_restart cannot be .false. in PMO', &
   source,revision,revdate)

end subroutine init_conditions


!------------------------------------------------------------------

! Writes the model-specific attributes to a netCDF file.
!     This includes coordinate variables and some metadata, but NOT
!     the model state vector.
!
! assim_model_mod:init_diag_output uses information from the location_mod
!     to define the location dimension and variable ID. All we need to do
!     is query, verify, and fill 
!
! Typical sequence for adding new dimensions,variables,attributes:
! NF90_OPEN             ! open existing netCDF dataset
!    NF90_redef         ! put into define mode 
!    NF90_def_dim       ! define additional dimensions (if any)
!    NF90_def_var       ! define variables: from name, type, and dims
!    NF90_put_att       ! assign attribute values
! NF90_ENDDEF           ! end definitions: leave define mode
!    NF90_put_var       ! provide values for variable
! NF90_CLOSE            ! close: save updated netCDF dataset

function nc_write_model_atts( ncFileID , local_model_mod_will_write_state_variables ) result (ierr)

integer, intent(in)  :: ncFileID      ! netCDF file identifier
logical, intent(out) :: local_model_mod_will_write_state_variables   ! if false, dart writes for us
integer              :: ierr          ! return value of function

integer :: nDimensions, nVariables, nAttributes, unlimitedDimID

! variables if we just blast out one long state vector

integer :: StateVarDimID   ! netCDF pointer to state variable dimension (model size)
integer :: MemberDimID     ! netCDF pointer to dimension of ensemble    (ens_size)
integer :: TimeDimID       ! netCDF pointer to time dimension           (unlimited)

integer :: StateVarVarID   ! netCDF pointer to state variable coordinate array
integer :: StateVarID      ! netCDF pointer to 3D [state,copy,time] array

! variables for the namelist output

character(len=129), allocatable, dimension(:) :: textblock
integer :: LineLenDimID, nlinesDimID, nmlVarID
integer :: nlines, linelen
logical :: has_model_namelist

! local variables 

! we are going to need these to record the creation date in the netCDF file.
! This is entirely optional, but nice.

character(len=8)      :: crdate      ! needed by F90 DATE_AND_TIME intrinsic
character(len=10)     :: crtime      ! needed by F90 DATE_AND_TIME intrinsic
character(len=5)      :: crzone      ! needed by F90 DATE_AND_TIME intrinsic
integer, dimension(8) :: values      ! needed by F90 DATE_AND_TIME intrinsic
character(len=NF90_MAX_NAME) :: time_str
integer :: i

character(len=128) :: filename

if ( .not. module_initialized ) call static_init_model()

ierr = -1 ! assume things go poorly
local_model_mod_will_write_state_variables = .false.  ! have dart do it


! we only have a netcdf handle here so we do not know the filename
! or the fortran unit number.  but construct a string with at least
! the netcdf handle, so in case of error we can trace back to see
! which netcdf file is involved.


write(filename,*) 'ncFileID', ncFileID


! make sure ncFileID refers to an open netCDF file, 
! and then put into define mode.


call nc_check(nf90_Inquire(ncFileID,nDimensions,nVariables,nAttributes,unlimitedDimID),&
                                   'nc_write_model_atts', 'inquire '//trim(filename))
call nc_check(nf90_Redef(ncFileID),'nc_write_model_atts',   'redef '//trim(filename))


! We need the dimension ID for the number of copies/ensemble members, and
! we might as well check to make sure that Time is the Unlimited dimension. 
! Our job is create the 'model size' dimension.


call nc_check(nf90_inq_dimid(ncid=ncFileID, name='NMLlinelen', dimid=LineLenDimID), &
                           'nc_write_model_atts','inq_dimid NMLlinelen')
call nc_check(nf90_inq_dimid(ncid=ncFileID, name='copy', dimid=MemberDimID), &
                           'nc_write_model_atts', 'copy dimid '//trim(filename))
call nc_check(nf90_inq_dimid(ncid=ncFileID, name='time', dimid=  TimeDimID), &
                           'nc_write_model_atts', 'time dimid '//trim(filename))

if ( TimeDimID /= unlimitedDimId ) then
   write(string1,*)'Time Dimension ID ',TimeDimID, &
             ' should equal Unlimited Dimension ID',unlimitedDimID
   call error_handler(E_ERR,'nc_write_model_atts', string1, source, revision, revdate)
endif


! Write Global Attributes 


call DATE_AND_TIME(crdate,crtime,crzone,values)
write(time_str,'(''YYYY MM DD HH MM SS = '',i4,5(1x,i2.2))') &
                  values(1), values(2), values(3), values(5), values(6), values(7)

call set_netcdf_string_attr(ncFileID, 'creation_date',  time_str,    filename)
call set_netcdf_string_attr(ncFileID, 'model_source',   source,      filename)
call set_netcdf_string_attr(ncFileID, 'model_revision', revision,    filename)
call set_netcdf_string_attr(ncFileID, 'model_revdate',  revdate,     filename)
call set_netcdf_string_attr(ncFileID, 'model',          'CM1 model', filename)


! Determine shape of most important namelist


call find_textfile_dims('namelist.input', nlines, linelen)
if (nlines > 0) then
  has_model_namelist = .true.
else
  has_model_namelist = .false.
endif

if ((debug > 0) .and. do_output()) then
   write(string1, *) 'model namelist: nlines, linelen = ', nlines, linelen
   call say(string1)
endif
  
if (has_model_namelist) then 
   allocate(textblock(nlines))
   textblock = ''

   call nc_check(nf90_def_dim(ncid=ncFileID, name='nlines', &
                 len = nlines, dimid = nlinesDimID), &
                 'nc_write_model_atts', 'def_dim nlines ')

   call nc_check(nf90_def_var(ncFileID,name='CM1_namelist', xtype=nf90_char,    &
                 dimids = (/ linelenDimID, nlinesDimID /),  varid=nmlVarID), &
                 'nc_write_model_atts', 'def_var model_in')
   call nc_check(nf90_put_att(ncFileID, nmlVarID, 'long_name',       &
                 'contents of model_in namelist'), 'nc_write_model_atts', 'put_att model_in')

endif


! Leave define mode
call nc_check(nf90_enddef(ncfileID),'nc_write_model_atts','state enddef '//trim(filename))


! Fill the variables we can

if (has_model_namelist) then
   call file_to_text('namelist.input', textblock)
   call nc_check(nf90_put_var(ncFileID, nmlVarID, textblock ), &
                 'nc_write_model_atts', 'put_var nmlVarID')
   deallocate(textblock)
endif

! Flush the buffer and leave netCDF file open

call nc_check(nf90_sync(ncFileID), 'nc_write_model_atts', 'atts sync')

ierr = 0 ! If we got here, things went well.

end function nc_write_model_atts


!------------------------------------------------------------------

! all errors are fatal, so the return code is always '0 == normal' 
! since the fatal errors stop execution.
!
! assim_model_mod:init_diag_output uses information from the location_mod
!     to define the location dimension and variable ID. All we need to do
!     is query, verify, and fill 
!
! Typical sequence for adding new dimensions,variables,attributes:
! NF90_OPEN             ! open existing netCDF dataset
!    NF90_redef         ! put into define mode
!    NF90_def_dim       ! define additional dimensions (if any)
!    NF90_def_var       ! define variables: from name, type, and dims
!    NF90_put_att       ! assign attribute values
! NF90_ENDDEF           ! end definitions: leave define mode
!    NF90_put_var       ! provide values for variable
! NF90_CLOSE            ! close: save updated netCDF dataset

function nc_write_model_vars( ncFileID, state_vec, copyindex, timeindex ) result (ierr)         

integer,                intent(in) :: ncFileID      ! netCDF file identifier
real(r8), dimension(:), intent(in) :: state_vec
integer,                intent(in) :: copyindex
integer,                intent(in) :: timeindex
integer                            :: ierr          ! return value of function

integer :: VarID
integer :: TimeDimID, CopyDimID

character(len=128) :: filename

if ( .not. module_initialized ) call static_init_model()

ierr = -1 ! assume things go poorly

! we only have a netcdf handle here so we do not know the filename
! or the fortran unit number.  but construct a string with at least
! the netcdf handle, so in case of error we can trace back to see
! which netcdf file is involved.

write(filename,*) 'ncFileID', ncFileID


! make sure ncFileID refers to an open netCDF file, 


call nc_check(nf90_inq_dimid(ncFileID, 'copy', dimid=CopyDimID), &
            'nc_write_model_vars', 'inq_dimid copy '//trim(filename))

call nc_check(nf90_inq_dimid(ncFileID, 'time', dimid=TimeDimID), &
            'nc_write_model_vars', 'inq_dimid time '//trim(filename))

! Flush the buffer and leave netCDF file open

call nc_check(nf90_sync(ncFileID), 'nc_write_model_vars', 'sync '//trim(filename))

ierr = 0 ! If we got here, things went well.

end function nc_write_model_vars


!------------------------------------------------------------------

! this version is used when running in RMA mode where the state
! vector is distributed - not all items in the state vector are
! on all MPI tasks.   if interf_provided, the calling routine will
! do the same perturbation as the routine above.

subroutine pert_model_copies(state_ens_handle, ens_size, pert_amp, interf_provided)

 type(ensemble_type), intent(inout) :: state_ens_handle
 integer,             intent(in)    :: ens_size
 real(r8),            intent(in)    :: pert_amp
 logical,             intent(out)   :: interf_provided

interf_provided = .false.

end subroutine pert_model_copies


!------------------------------------------------------------------

! Given a DART location (referred to as "base") and a set of candidate
! locations & kinds (obs, obs_kind), returns the subset close to the
! "base", their indices, and their distances to the "base" ...

! Vertical conversion is carried out by the subroutine vert_convert.

! Note that both base_obs_loc and obs_loc are intent(inout), meaning that these
! locations are possibly modified here and returned as such to the calling routine.
! The calling routine is always filter_assim and these arrays are local arrays
! within filter_assim. In other words, these modifications will only matter within
! filter_assim, but will not propagate backwards to filter.

subroutine get_close_obs(gc, base_obs_loc, base_obs_kind, &
                         obs_loc, obs_kind, num_close, close_ind, dist, state_ens_handle)

type(get_close_type),              intent(in)    :: gc
type(location_type),               intent(inout) :: base_obs_loc
integer,                           intent(in)    :: base_obs_kind
type(location_type), dimension(:), intent(inout) :: obs_loc
integer,             dimension(:), intent(in)    :: obs_kind
integer,                           intent(out)   :: num_close
integer,             dimension(:), intent(out)   :: close_ind
real(r8), optional,  dimension(:), intent(out)   :: dist
type(ensemble_type),               intent(in)    :: state_ens_handle


   ! Loop over potentially close subset of obs priors or state variables
   ! This way, we are decreasing the number of distance computations that will follow.
   ! This is a horizontal-distance operation and we don't need to have the relevant vertical
   ! coordinate information yet (for obs_loc).
   call loc_get_close_obs(gc, base_obs_loc, base_obs_kind, obs_loc, obs_kind, &
                          num_close, close_ind, dist)

end subroutine get_close_obs

!------------------------------------------------------------------

! This subroutine converts a given ob/state vertical coordinate to
! the vertical localization coordinate type requested through the
! model_mod namelist.
!
! Notes: (1) obs_kind is only necessary to check whether the ob
!            is an identity ob.
!        (2) This subroutine can convert both obs' and state points'
!            vertical coordinates. Remember that state points get
!            their DART location information from get_state_meta_data
!            which is called by filter_assim during the assimilation
!            process.
!        (3) x is the relevant DART state vector for carrying out
!            computations necessary for the vertical coordinate
!            transformations. As the vertical coordinate is only used
!            in distance computations, this is actually the "expected"
!            vertical coordinate, so that computed distance is the
!            "expected" distance. Thus, under normal circumstances,
!            x that is supplied to vert_convert should be the
!            ensemble mean. Nevertheless, the subroutine has the
!            functionality to operate on any DART state vector that
!            is supplied to it.

subroutine vert_convert(state_ens_handle, location, obs_kind, vstatus)

type(ensemble_type),    intent(in)    :: state_ens_handle
type(location_type),    intent(inout) :: location
integer,                intent(in)    :: obs_kind
integer,                intent(out)   :: vstatus

integer :: ens_size


ens_size = copies_in_window(state_ens_handle)

! FIXME: completely dummied out for now

vstatus = 0

end subroutine vert_convert

!------------------------------------------------------------------
!
! given a set of multiple distributed state vectors, a location and 
! generic obs kind, return a set of expected obs values and a 
! success/failure code
!
!       ISTATUS = 12: observation not contained within grid
!
subroutine model_interpolate(state_ens_handle, ens_size, location, obs_type, expected_obs, istatus)

! passed variables

type(ensemble_type), intent(in)  :: state_ens_handle
integer,             intent(in)  :: ens_size
type(location_type), intent(in)  :: location
integer,             intent(in)  :: obs_type
real(r8),            intent(out) :: expected_obs(ens_size)
integer,             intent(out) :: istatus(ens_size)

! local storage

integer     :: obs_kind
real(r8)    :: obs_loc_array(3)
integer     :: i ! loop indices
integer     :: x_ind(2), y_ind(2), z_ind(2) !  bounding box indices
real(r8)    :: x_val(2), y_val(2), z_val(2) !  bounding box values
integer(i8) :: indx
integer     :: hstatus ! for non-sgrid height interpolation

! need to know
integer :: nlevs ! number of levels (zhalf and zfull have different number?)
integer :: varid
integer :: ndims
real(r8), allocatable :: Q11_ens(:, :), Q12_ens(:, :), Q21_ens(:, :), Q22_ens(:, :)
real(r8), allocatable :: P_ens(:, :)
integer :: axis_length

if ( .not. module_initialized ) call static_init_model()

expected_obs(:) = MISSING_R8
istatus(:)      = 99         

! rename for sanity - we can't change the argument names
! to this subroutine, but this really is a kind.
obs_kind = obs_type

if (debug > 0) then
   call write_location(0,location,charstring=string1)
   write(string1, *) my_task_id(), 'kind, loc ', obs_kind, trim(string1)
   call say(string1)
endif

obs_loc_array = get_location(location)

varid = get_varid_from_kind(domid, obs_kind)
nlevs = get_z_axis_length(varid)
ndims = get_num_dims(domid, varid)
! 2d vs. 3d variable test
if (ndims == 3) then
   nlevs = 2
else ! 2D, surface obs
   nlevs = 1
endif


if( .not. observation_on_grid(obs_loc_array, ndims) ) then
   ! no need to interpolate
   istatus(:) = 12
   return ! exit early
endif

if (debug > 0) print*, 'nlevs', nlevs

! Interpolate the height field (z) to get the height at each level at 
! the observation location. This allows us to find which level an observation 
! is in.

! Find the x, y enclosing box on the variable grid (which ever grid the variable is on).
! Need grid from kind
call get_x_axis(varid, axis, axis_length)
call get_enclosing_coord(obs_loc_array(1), axis(1:axis_length), x_ind, x_val)

call get_y_axis(varid, axis, axis_length)
call get_enclosing_coord(obs_loc_array(2), axis(1:axis_length), y_ind, y_val)

! wrap the indicies if the observation is near the boundary
if (periodic_x) call wrap_x( obs_loc_array(1), x_ind, x_val )
if (periodic_y) call wrap_y( obs_loc_array(2), y_ind, y_val )

if (nlevs == 2) then ! you need to find which 2 levels you are between
   ! If variable is on ni, nj grid:
   if (is_on_s_grid(varid)) then
      call height_interpolate_s_grid(obs_loc_array, varid, nlevs, z_ind, z_val)
   else
      call height_interpolate(obs_loc_array, varid, nlevs, x_ind, y_ind, z_ind, x_val, y_val, z_val, hstatus)
      if (hstatus /= 0) return
   endif

if (debug > 0) print*, 'x y enclosing', x_ind, y_ind, x_val, y_val

if (debug > 0) print*, 'nlevs: ', nlevs, ', num_dims:', get_num_dims(domid, varid)

if (debug > 0) print*, 'z_ind', z_ind, 'varid', varid

endif

! top and bottom, or just one value if 2d variable
allocate(Q11_ens(ens_size, nlevs))
allocate(Q12_ens(ens_size, nlevs))
allocate(Q21_ens(ens_size, nlevs))
allocate(Q22_ens(ens_size, nlevs))

! interpolated value
allocate(P_ens(ens_size, nlevs))

do i = 1, nlevs
   indx = get_dart_vector_index(x_ind(1), y_ind(1), z_ind(i), domid, varid)
   Q11_ens(:, i) = get_state(indx, state_ens_handle)
   indx = get_dart_vector_index(x_ind(1), y_ind(2), z_ind(i), domid, varid)
   Q12_ens(:, i) = get_state(indx, state_ens_handle)
   indx = get_dart_vector_index(x_ind(2), y_ind(1), z_ind(i), domid, varid)
   Q21_ens(:, i) = get_state(indx, state_ens_handle)
   indx = get_dart_vector_index(x_ind(2), y_ind(2), z_ind(i), domid, varid)
   Q22_ens(:, i) = get_state(indx, state_ens_handle)
if (debug > 0)    print*,'level :', i  
if (debug > 0)    print*,'   Q11, Q12, Q21, Q22', Q11_ens(:,1), Q12_ens(:,1), Q21_ens(:,1), Q22_ens(:,1)
enddo

! P_ens is the interpolated value at the level below and above the obs for each ensemble member.
! P_ens is (ens_size, nlevs)
P_ens(:, :) = bilinear_interpolation_ens(ens_size, nlevs, obs_loc_array(1), obs_loc_array(2), &
                              x_val(1), x_val(2),y_val(1) , y_val(2), Q11_ens, Q12_ens, Q21_ens, Q22_ens)

deallocate(Q11_ens, Q12_ens, Q21_ens, Q22_ens)

! Interpolate between P to get the expected value

! If 2d don't call this.
if (nlevs == 2) then
   expected_obs = linear_interpolation(ens_size, obs_loc_array(3), z_val(1), z_val(2), P_ens(:, 1), P_ens(:, 2) )
else
   expected_obs = P_ens(:,1)
endif

istatus(:) = 0

end subroutine model_interpolate

!--------------------------------------------------------------------
!> For variables on the horizontal s grid
!> Interpolate height from corners of the bounding box locations to the
!> observation location.
subroutine height_interpolate_s_grid(obs_loc_array, varid, nlevs, z_ind, z_val)

real(r8), intent(in)  :: obs_loc_array(3)
integer,  intent(in)  :: varid
integer,  intent(in)  :: nlevs

integer,  intent(out) :: z_ind(2)
real(r8), intent(out) :: z_val(2)

real(r8) :: Q11(nlevs), Q12(nlevs), Q21(nlevs), Q22(nlevs)
real(r8) :: Z(nlevs) ! array of heights for every level at the obsevation x,y locatoin
integer :: level
integer     :: x_ind(2), y_ind(2) !  bounding box indices
real(r8)    :: x_val(2), y_val(2) !  bounding box values


! Find enclosing xy box indices on the height grid. Height is always on the
! ni, nj grid (which is xh, yh). What about extrapolation?
call get_enclosing_coord(obs_loc_array(1), xh, x_ind, x_val)
call get_enclosing_coord(obs_loc_array(2), yh, y_ind, y_val)

! wrap the indicies if the observation is near the boundary
if(periodic_x) call wrap_x( obs_loc_array(1), x_ind, x_val )
if(periodic_y) call wrap_y( obs_loc_array(2), y_ind, y_val )

if (debug > 0) print *, 'enclosing in height_interpolate_s_grid ', x_ind, y_ind

! I don't think you need to make these copies
if (nlevs == nk) then

   do level = 1, nlevs
      Q11(level) = zhalf(x_ind(1), y_ind(1), level)
      Q12(level) = zhalf(x_ind(1), y_ind(2), level)
      Q21(level) = zhalf(x_ind(2), y_ind(1), level)
      Q22(level) = zhalf(x_ind(2), y_ind(2), level)

   enddo

else ! on z half levels

   do level = 1, nlevs
      Q11(level) = zfull(x_ind(1), y_ind(1), level)
      Q12(level) = zfull(x_ind(1), y_ind(2), level)
      Q21(level) = zfull(x_ind(2), y_ind(1), level)
      Q22(level) = zfull(x_ind(2), y_ind(2), level)
   enddo

endif


! Z is the height at the xy location of the obs for each level.
Z(:) = bilinear_interpolation(nlevs, obs_loc_array(1), obs_loc_array(2), &
                              x_val(1), x_val(2), y_val(1), y_val(2), Q11, Q12, Q21, Q22)

!print*, 'Z(:)', Z(:)

! Find out which level the point is in:
call get_enclosing_coord(obs_loc_array(3), Z, z_ind, z_val)

!print*, 'level', z_ind, z_val

end subroutine height_interpolate_s_grid

!--------------------------------------------------------------------
!> For variables not on the horizonal s grid
!> Interpolate from the height field (zhalf or zfull) to the bounding box
!> of the observation. Then interpolate the height at each corner of the
!> bounding box to the observation location
subroutine height_interpolate(obs_loc_array, varid, nlevs, x_ind, y_ind, z_ind, x_val, y_val, z_val, istatus)

real(r8), intent(in)  :: obs_loc_array(3)
integer,  intent(in)  :: varid
integer,  intent(in)  :: nlevs
integer,  intent(in)  :: x_ind(2) ! x indices on on the variable grid
integer,  intent(in)  :: y_ind(2) ! y indices on on the variable grid
integer,  intent(out) :: z_ind(2)
real(r8), intent(in)  :: x_val(2)
real(r8), intent(in)  :: y_val(2)
real(r8), intent(out) :: z_val(2)
integer,  intent(out) :: istatus ! same across the ensemble

real(r8) :: Q11(nlevs), Q12(nlevs), Q21(nlevs), Q22(nlevs)
real(r8) :: P1(2, nlevs), P2(2, nlevs), T1(2, nlevs), T2(2, nlevs)
real(r8) :: Z(nlevs) ! array of heights for every level at the obsevation x,y location
integer  :: level, i, j, k
integer  :: staggered_ind(3) !  Z bounding boxes indices

! Linearly interpolate from height to staggered grid. This is 6 unique points,
! since there is only stagger in one direction.

! x = u points
! . = scalar points
! o = observation location

! -.-x-.-x-.-
!  | o |   |
! -.-x-.-x-.-

! Need to interpolate height from . to x
! Then from height at x to observation location o.
!                     x - x
!                     | o |
!                     x - x

!> @todo You don't have to loop around dimensions - on_ugrid and on_vgrid is calculated
!> during static_init_model_mod and stored in module global storage.  See get_state_meta_data
!> for an example of usage.
do i = 1, get_num_dims(domid, varid)
   if(get_dim_name(domid, varid, i) == 'nj') then ! on u grid

      do j = 1, 2

         staggered_ind(1) = x_ind(j) - 1
         staggered_ind(2) = x_ind(j)
         staggered_ind(3) = x_ind(j) + 1

         !> @todo peridic and off the grid

         ! periodic boundary conditions
         do k = 1,3
            ! wrap at min grid cell
            if (staggered_ind(k) <= 0) then
               staggered_ind(k) = staggered_ind(k) + nj
            endif

            ! wrap at max grid cell
            if (staggered_ind(k) > nj) then
               staggered_ind(k) = staggered_ind(k) - nj
            endif
         enddo

if (debug > 0) then
   print *, 'X staggered_ind(1) : ', staggered_ind(1)
   print *, 'X staggered_ind(2) : ', staggered_ind(2)
   print *, 'X staggered_ind(3) : ', staggered_ind(3)
endif
        
         do level = 1, nlevs

            P1(j, level) = zhalf(staggered_ind(1), y_ind(1), level)
            P2(j, level) = zhalf(staggered_ind(2), y_ind(2), level)

            T1(j, level) = zhalf(staggered_ind(2), y_ind(1), level)
            T2(j, level) = zhalf(staggered_ind(3), y_ind(2), level)

         enddo

      enddo

     ! Linear interpolaion to get height at 4 points on u grid at each level
      Q11(:) = linear_interpolation(nlevs, xf(x_ind(1)), xh(staggered_ind(1)), xh(staggered_ind(2)), P1(1, :), P2(1, :))
      Q12(:) = linear_interpolation(nlevs, xf(x_ind(2)), xh(staggered_ind(2)), xh(staggered_ind(3)), T1(1, :), T2(1, :))
      Q21(:) = linear_interpolation(nlevs, xf(x_ind(1)), xh(staggered_ind(1)), xh(staggered_ind(2)), P1(2, :), P2(1, :))
      Q22(:) = linear_interpolation(nlevs, xf(x_ind(2)), xh(staggered_ind(2)), xh(staggered_ind(3)), T1(2, :), T2(2, :))


   elseif(get_dim_name(domid, varid, i) == 'ni') then ! on v grid

! x = v points
! . = scalar points
! o = observation location

!  . - .
!  |   |
!  x - x
!  | o |
!  . - .
!  |   |
!  x - x
!  |   |
!  . - .

! Need to interpolate height from . to x
! Then from height at x to observation location o.
!                     x - x
!                     | o |
!                     x - x

      do j = 1, 2

         staggered_ind(1) = y_ind(j) - 1
         staggered_ind(2) = y_ind(j)
         staggered_ind(3) = y_ind(j) + 1

         !> @todo peridic and off the grid

         ! periodic boundary conditions
         do k = 1,3
            ! wrap at min grid cell
            if (staggered_ind(k) <= 0) then
               staggered_ind(k) = staggered_ind(k) + ni
            endif

            ! wrap at max grid cell
            if (staggered_ind(k) > ni) then
               staggered_ind(k) = staggered_ind(k) - ni
            endif
         enddo

if (debug > 0) print *, 'Y staggered_ind(1) : ', staggered_ind(1)
if (debug > 0) print *, 'Y staggered_ind(2) : ', staggered_ind(2)
if (debug > 0) print *, 'Y staggered_ind(3) : ', staggered_ind(3)

         do level = 1, nlevs

            P1(j, level) = zhalf(x_ind(1), staggered_ind(1), level)
            P2(j, level) = zhalf(x_ind(2), staggered_ind(2), level)

            T1(j, level) = zhalf(x_ind(1), staggered_ind(2), level)
            T2(j, level) = zhalf(x_ind(2), staggered_ind(3), level)

         enddo

      enddo

     ! Linear interpolaion to get height at 4 points on v grid at each level
      Q11(:) = linear_interpolation(nlevs, yf(y_ind(1)), xh(staggered_ind(1)), yh(staggered_ind(2)), P1(1, :), P2(1, :))
      Q12(:) = linear_interpolation(nlevs, yf(y_ind(2)), yh(staggered_ind(2)), yh(staggered_ind(3)), T1(1, :), T2(1, :))
      Q21(:) = linear_interpolation(nlevs, yf(y_ind(1)), yh(staggered_ind(1)), yh(staggered_ind(2)), P1(2, :), P2(1, :))
      Q22(:) = linear_interpolation(nlevs, yf(y_ind(2)), yh(staggered_ind(2)), yh(staggered_ind(3)), T1(2, :), T2(2, :))


   endif

enddo

! Z is the height at the xy location of the obs for each level.

! interpolate to the observation location
Z(:) = bilinear_interpolation(nlevs, obs_loc_array(1), obs_loc_array(2), &
                              x_val(1), x_val(2), y_val(1), y_val(2), Q11, Q12, Q21, Q22)


! Find out which level the point is in:
call get_enclosing_coord(obs_loc_array(3), Z, z_ind, z_val)

!>@todo Can this fail if you go outside the grid?
istatus = 0

end subroutine height_interpolate

!--------------------------------------------------------------------
!> Test if an observation is on the grid
function observation_on_grid(obs_location, ndims)

real(r8), intent(in) :: obs_location(3)
integer,  intent(in) :: ndims 

logical :: observation_on_grid

! check that we have a valid number of dimensions
if ( ndims < 2 .or. ndims > 3 ) then
   write(string1,*) ' invalid ndims ', ndims, ', only checking 2 and 3 dimensional variables'
   call error_handler(E_ERR,'observation_on_grid',string1,source,revision,revdate)
endif

! start out assuming that the observation is on the grid
observation_on_grid = .true.

! this is for periodidc x and y. would need to extrapolate for z so enforce
! that observation is in the half grid
if ( periodic_x .and. periodic_y ) then
   if ( (obs_location(1) < xf(1)) .or. (obs_location(1) > xf(nip1)) .or. &
        (obs_location(2) < yf(1)) .or. (obs_location(2) > yf(njp1)) ) then

      observation_on_grid = .false. 

      if (debug > 0) then
         print *, 'periodic boundary conditions'
         print *, 'OBSERVATION_x,y at ', obs_location(1:2), ' is off x,y grid'
         print *, 'x_min, x_max ', xf(1), xf(nip1)
         print *, 'y_min, y_max ', yf(1), yf(njp1)
      endif

      return ! exit early

   endif 
elseif ( (.not. periodic_x) .and. (.not. periodic_y) ) then
   ! require that the point is contained within the staggered grid for now.
   ! you could extrapolate for values that are within xf-xh, yf-yh
   ! with some extra work.
   if ( (obs_location(1) < xh(1)) .or. (obs_location(1) > xh(ni)) .or. &
        (obs_location(2) < yh(1)) .or. (obs_location(2) > yh(nj)) ) then

      observation_on_grid = .false. 

      if (debug > 0) then
         print *, 'non-periodic boundary conditions'
         print *, 'OBSERVATION_x,y at ', obs_location(1:2), ' is off x,y grid'
         print *, 'x_min, x_max ', xh(1), xh(ni)
         print *, 'y_min, y_max ', yh(1), yh(nj)
      endif
      
      return ! exit early

   endif
else
   write(string1,*) 'only grids with periodic x and y grids, or non-periodic '
   write(string2,*) 'boundary conditions supported'
   call error_handler(E_ERR, 'observation_on_grid', string1, &
                  source, revision, revdate, text2=string2)
endif

! check that the vertical dimension is contained within zh for 3D vaiables
if (ndims == 3) then
   ! require that the point is contained within the staggered grid.
   ! you could extrapolate for values that are within zf-zh
   ! with some extra work.
   if ( (obs_location(3) < zh(1)) .or. (obs_location(3) > zh(nk)) )  then

      observation_on_grid = .false. 

      if (debug > 0) then
         print *, 'outside z grid'
         print *, 'OBSERVATION_z at ', obs_location(3), ' is off z grid'
         print *, 'z_min, z_max ', zh(1), zh(nk)
      endif

      return ! exit early

   endif
endif

end function observation_on_grid

!--------------------------------------------------------------------
!> Test if a variable is on the s grid
function is_on_s_grid(varid)

integer, intent(in) :: varid

logical :: is_on_s_grid

integer :: i
logical :: on_ni, on_nj

on_nj = .false.
on_ni = .false.

do i = 1, get_num_dims(domid, varid)
   if(get_dim_name(domid, varid, i) == 'ni') on_ni = .true.
   if(get_dim_name(domid, varid, i) == 'nj') on_nj = .true.
enddo


is_on_s_grid = (on_ni .and. on_nj)

end function

!--------------------------------------------------------------------
!> Return the x axis and length of the x axis
subroutine get_x_axis(varid, axis, axis_length)

integer,  intent(in)  :: varid
real(r8), intent(out) :: axis(:)
integer,  intent(out) :: axis_length

integer :: i

do i = 1, get_num_dims(domid, varid)
   if(get_dim_name(domid, varid, i) == 'ni') then
      axis_length = get_dim_length(domid, varid, i)
      axis(1:axis_length) = xh(:)
      exit
   endif

    if(get_dim_name(domid, varid, i) == 'nip1') then
      axis_length = get_dim_length(domid, varid, i)
      axis(1:axis_length) = xf(:)
      exit
   endif
enddo

end subroutine get_x_axis

!--------------------------------------------------------------------
!> Return the y axis and length of the z axis
subroutine get_y_axis(varid, axis, axis_length)

integer,  intent(in)  :: varid
real(r8), intent(out) :: axis(:)
integer,  intent(out) :: axis_length

integer :: i

do i = 1, get_num_dims(domid, varid)
   if(get_dim_name(domid, varid, i) == 'nj') then
      axis_length = get_dim_length(domid, varid, i)
      axis(1:axis_length) = yh(:)
      exit
   endif
    if(get_dim_name(domid, varid, i) == 'njp1') then
      axis_length = get_dim_length(domid, varid, i)
      axis(1:axis_length) = yf(:)
      exit
   endif
enddo

end subroutine get_y_axis

!--------------------------------------------------------------------
!> Return the length of the z axis
function get_z_axis_length(varid)

integer, intent(in)  :: varid
integer :: get_z_axis_length

integer :: i, ndims
character(len=NF90_MAX_NAME) :: dimname

ndims = get_num_dims(domid, varid)

do i = 1, ndims

   dimname = get_dim_name(domid, varid, i)

   if(dimname == 'nk') then
      get_z_axis_length = get_dim_length(domid, varid, i)
      exit
   elseif (dimname == 'nkp1') then
      get_z_axis_length = get_dim_length(domid, varid, i)
      exit
   else ! no z-dimension
      get_z_axis_length = 1
   endif

enddo

end function get_z_axis_length

!--------------------------------------------------------------------
!> For periodic boundary conditions in the x direction.
subroutine wrap_x(obs_x_loc, x_ind, x_val)

real(r8), intent(in)    :: obs_x_loc
integer,  intent(inout) :: x_ind(2) !  bounding box indices
real(r8), intent(inout) :: x_val(2) !  bounding box values

! wrap in x if observation location is between xf(1) and xh(1)
if ( obs_x_loc <= xh(1) .and. obs_x_loc >= xf(1) ) then ! x is off the grid

   x_ind(1) = 1 
   x_ind(2) = ni
   x_val(1) = xh(1)
   x_val(2) = xh(ni) - xf(nip1) ! subtracting lenght of grid to get correct
                                ! distance for interpolation
   if (debug > 0) then

      print*, 'OBS_X_LOC, xh(1) :' , obs_x_loc, xh(1)
      print*, ' wrapping back in the x-direction'
      print*, 'x_val, xh(ni) , xf(nip1) ', x_val, xh(ni) , xf(nip1)
   endif

endif

! wrap in x if observation location is between xh(ni) and xf(nip1)
if ( obs_x_loc > xh(ni) .and. obs_x_loc <= xf(nip1) ) then ! x is off the grid

   x_ind(1) = 1
   x_ind(2) = ni
   x_val(1) = xh(ni)
   x_val(2) = xh(1) + xf(nip1) ! adding lenght of grid to get correct
                               ! distance for interpolation

   if (debug > 0) then
      print*, 'OBS_X_LOC, xh(ni) :' , obs_x_loc, xh(1)
      print*, ' wrapping forward the x-direction'
      print*, 'x_val, xh(ni) , xf(nip1) ', x_val, xh(ni) , xf(nip1)
   endif

endif

end subroutine wrap_x

!--------------------------------------------------------------------
!> For periodic boundary conditions in the y direction.
subroutine wrap_y(obs_y_loc, y_ind, y_val)

real(r8), intent(in) :: obs_y_loc
integer , intent(inout) :: y_ind(2) !  bounding box indices
real(r8), intent(inout) :: y_val(2) !  bounding box values

! wrap in y if observation location is between yf(1) and yh(1)
if ( obs_y_loc <= yh(1) .and. obs_y_loc >= yf(1) ) then ! y is off the grid

   y_ind(1) = 1 
   y_ind(2) = nj
   y_val(1) = yh(1)
   y_val(2) = yh(nj) - yf(njp1) ! subtracting lenght of grid to get correct
                                ! distrance for interpolation

   if (debug > 0 ) then
      print*, 'OBS_Y_LOC, yh(1) :' , obs_y_loc, yh(1)
      print*, ' wrapping back in the y-direction'
      print*, 'y_val, yh(nj) , yf(njp1) ', y_val, yh(nj) , yf(njp1)
   endif

endif

! wrap in y if observation location is between yh(nj) and yf(njp1)
if ( obs_y_loc > yh(nj) .and. obs_y_loc <= yf(njp1) ) then ! y is off the grid

   y_ind(1) = 1
   y_ind(2) = nj
   y_val(1) = yh(nj)
   y_val(2) = yh(1) + yf(njp1) ! adding length of grid to get correct
                               ! distance for interpolation

   if (debug > 0) then
      print*, 'OBS_Y_LOC, yh(nj) :' , obs_y_loc, yh(1)
      print*, ' wrapping forward the y-direction'
      print*, 'y_val, yh(nj) , yf(njp1) ', y_val, yh(nj) , yf(njp1)
   endif

endif

end subroutine wrap_y

!--------------------------------------------------------------------

!--------------------------------------------------------------------
!> Performs bilinear interpolation.
!> Acts on arrays so you can do a whole column in one function call

function bilinear_interpolation(n, x, y, x1,x2, y1, y2, Q11, Q12, Q21, Q22) result (P)

integer,  intent(in)  :: n ! number of interpolations - e.g. layers in a column
real(r8), intent(in)  :: x, y ! location of point to interpolate to
real(r8), intent(in)  :: x1, x2 ! x coordinates of box
real(r8), intent(in)  :: y1, y2 ! y coordinates of box
real(r8), intent(in)  :: Q11(n)
real(r8), intent(in)  :: Q12(n)
real(r8), intent(in)  :: Q21(n)
real(r8), intent(in)  :: Q22(n)
real(r8)              :: P(n)

real(r8) :: R1(n), R2(n)
real(r8) :: xfrac, yfrac

xfrac = (x2 - x)/(x2 -x1)
yfrac = (y2 - y)/(y2 -y1)

R1 = xfrac*Q11 + (1-xfrac)*Q21
R2 = xfrac*Q12 + (1-xfrac)*Q22

P = yfrac*R1 + (1-yfrac)*R2

end function bilinear_interpolation

!--------------------------------------------------------------------
!> Performs bilinear interpolation.
!> Acts on arrays so you can do a whole column in one function call
function bilinear_interpolation_ens(m, n, x, y, x1,x2, y1, y2, Q11, Q12, Q21, Q22) result (P)

integer,  intent(in)  :: m ! ensemble_size - why not do the whole ensemble at once?
integer,  intent(in)  :: n ! number of interpolations - e.g. layers in a column
real(r8), intent(in)  :: x, y ! location of point to interpolate to
real(r8), intent(in)  :: x1, x2 ! x coordinates of box
real(r8), intent(in)  :: y1, y2 ! y coordinates of box
real(r8), intent(in)  :: Q11(m, n)
real(r8), intent(in)  :: Q12(m, n)
real(r8), intent(in)  :: Q21(m, n)
real(r8), intent(in)  :: Q22(m, n)
real(r8)              :: P(m, n)

real(r8) :: R1(m, n), R2(m, n)
real(r8) :: xfrac, yfrac

xfrac = (x2 - x)/(x2-x1)
yfrac = (y2 - y)/(y2 -y1)

R1 = xfrac*Q11 + (1-xfrac)*Q21
R2 = xfrac*Q12 + (1-xfrac)*Q22

P = yfrac*R1 + (1-yfrac)*R2

end function bilinear_interpolation_ens

!--------------------------------------------------------------------
function linear_interpolation(n, z, z1, z2, P1, P2) result (val)

integer,  intent(in) :: n ! length of array to interpolate on (e.g. ens_size)
real(r8), intent(in) :: z ! observation location
real(r8), intent(in) :: z1, z2 ! z coordinate of bounding box (not really a box, its a line)
real(r8), intent(in) :: P1(n), P2(n)
real(r8) :: val(n)

real(r8) :: zfrac

if (debug > 0) print*, 'P1, P2', P1, P2

zfrac = (z2 - z) / (z2 - z1)

if (debug > 0) print*, 'zfrac', zfrac

val(:) = zfrac*P1(:) + (1-zfrac)*P2(:)

if (debug > 0) print*, 'val', val

end function linear_interpolation

!--------------------------------------------------------------------
!> Returns the enclosing INCIDIES and VALUES for a given point on an axis
!> @todo FIXME Are all the comments in this routine about being off
!> the grid still true? The calling code above gives the correct axis
!> for the variable kind.
!> The observation being off the grid is checked before any call to 
!> get_enclosing_coord
subroutine get_enclosing_coord(x, xcoords, ind, val)

real(r8), intent(in)  :: x ! observation point in 1 dimension
real(r8), intent(in)  :: xcoords(:) ! array of grid values in that dimension. Assumes increasing
integer,  intent(out) :: ind(2) ! lower, upper indices
real(r8), intent(out) :: val(2) ! lower, upper values

integer :: i

ind(:) = -999
val(:) = MISSING_R8

if (x < xcoords(1)) then ! x is off the grid - happens with height - extrapolate
  call error_handler(E_ERR, 'get_enclosing_coord', 'off the grid, unexpected 1', &
                     source, revision, revdate)
endif

xloop: do i = 2, size(xcoords)
   if(x <= xcoords(i)) then  ! does this work?
      ind(1) = i -1 !> What if x is outside the grid?
      ind(2) = i    !> @todo What if x is the last in the array?
      ! periodic vs. bail out.
      val(1) = xcoords(ind(1))
      val(2) = xcoords(ind(2))
      exit xloop
   endif

   ! y is off the grid - this happens with height - extrapolate
   ! What if it is not height? I don't know.

 !> @todo What is this error message trying to do?
 !> It gets called every time x > xcoords(i)
 ! call error_handler(E_ERR, 'get_enclosing_coord', 'off the grid, unexpected 2', &
  !                   source, revision, revdate)

enddo xloop

if (ind(1) == -999) then
  call error_handler(E_ERR, 'get_enclosing_coord', 'off the grid, unexpected 3', &
                     source, revision, revdate)
endif

end subroutine get_enclosing_coord

!--------------------------------------------------------------------

!> pass the vertical localization coordinate to assim_tools_mod

function query_vert_localization_coord()

integer :: query_vert_localization_coord

query_vert_localization_coord = 0

end function query_vert_localization_coord

!--------------------------------------------------------------------

!> read the time from the input file
!> gets the start time of the experiment from the global attributes
!> and the current offset, in seconds, from the time() variable.
!>
!> @todo FIXME should only process 0 read this and broadcast it
!> to all the other tasks instead of everyone opening the same 
!> file at the same time?

function read_model_time(filename)

character(len=*), intent(in) :: filename
type(time_type)              :: read_model_time

! local variables
integer :: ret   ! return code for netcdf
integer :: ncid, VarID, numdims
integer, dimension(NF90_MAX_VAR_DIMS) :: dimIDs, idims
type(time_type) :: base_time
integer, allocatable :: seconds(:)
integer :: year, month, day, hour, minute, second

!> these were also in the param9 namelist - do we need them?
!> we might want the location, and set the origin of the local
!> grid to that place. FIXME  @todo
!>integer  :: radopt = 0
!>real(r8) :: dtrad  = 300.0_r8
!>real(r8) :: ctrlat = 0.0_r8
!>real(r8) :: ctrlon = 0.0_r8


if ( .not. module_initialized ) call static_init_model()

if (debug > 0) print *, 'read_model_time was called to get time from: '//trim(filename)

ret = nf90_open(filename, NF90_NOWRITE, ncid)
call nc_check(ret, 'opening', filename)

! The netcdf files have the time since the start of the experiment
! in the 'time' variable.
! The start of the experiment is in global attributes.

! FIXME: get the times from the attributes

year   = get_netcdf_integer_attr(ncid, "year", filename)
month  = get_netcdf_integer_attr(ncid, "month", filename)
day    = get_netcdf_integer_attr(ncid, "day", filename)
hour   = get_netcdf_integer_attr(ncid, "hour", filename)
minute = get_netcdf_integer_attr(ncid, "minute", filename)
second = get_netcdf_integer_attr(ncid, "second", filename)

base_time = set_date(year, month, day, hour, minute, second)

call nc_check( nf90_inq_varid(ncid, 'time', VarID), &
              'read_model_time', 'inquire time '//trim(filename))

call nc_check( nf90_inquire_variable(ncid, VarID, dimids=dimIDs, ndims=numdims), &
              'read_model_time', 'inquire TIME '//trim(filename))

if (numdims /= 1) then
   write(string1,*) 'time variable has unknown shape in ', trim(filename)
   call error_handler(E_ERR,'read_model_time',string1,source,revision,revdate)
endif

call nc_check( nf90_inquire_dimension(ncid, dimIDs(1), len=idims(1)), &
                 'read_model_time', 'inquire time dimension length '//trim(filename))

! Either this or use the start/count arrays ...
allocate(seconds(idims(1)))

call nc_check( nf90_get_var(ncid, VarID, seconds), &
              'read_model_time', 'get_var time '//trim(filename))

second = seconds(idims(1)) ! the last one.

if (debug > 99 .and. do_output()) call say('getting ready to return model time')
read_model_time = base_time + set_time(second, days=0)
 
deallocate(seconds)

ret = nf90_close(ncid)
call nc_check(ret, 'closing', filename)

if ((debug > 99) .and. do_output()) then
   write(string1,*) 'read_model_time was called to get date/time from: '//trim(filename)
   call say(string1)
   call print_date(base_time, 'read_model_time:starting date')
   call print_time(base_time, 'read_model_time:starting time')
   write(string1,*)'model offset is ',second ,' seconds.'
   call say(string1)
   call print_date(read_model_time, 'read_model_time:current model date')
   call print_time(read_model_time, 'read_model_time:current model time')
endif

end function read_model_time

!==================================================================
! FIXME!!!  some things below here are needed; others are NOT.
! figure out what's here, and why.
!==================================================================

!------------------------------------------------------------------

! parse a string to extract time.  the expected format of
! the string is YYYY-MM-DD hh:mm:ss  (although the exact
! non-numeric separator chars are skipped and not validated.)

function string_to_time(s)

type(time_type) :: string_to_time
character(len=*), intent(in) :: s

integer :: iyear, imonth, iday, ihour, imin, isec

read( s ,'(i4,5(1x,i2))') iyear, imonth, iday, ihour, imin, isec
string_to_time = set_date(iyear, imonth, iday, ihour, imin, isec)

end function string_to_time

!-------------------------------------------------------

! return a global integer attribute from a netcdf file

function get_netcdf_integer_attr(ncid, varname, filename)

integer,          intent(in) :: ncid
character(len=*), intent(in) :: varname
character(len=*), intent(in) :: filename
integer                      :: get_netcdf_integer_attr

integer :: rc, val

rc = nf90_inquire_attribute(ncid, NF90_GLOBAL, varname)
call nc_check( rc, 'inquire global integer attribute ', varname //' from '//trim(filename))

rc = nf90_get_att(ncid, NF90_GLOBAL, varname, val)
call nc_check( rc, 'get global integer attribute ', varname //' from '//trim(filename))

get_netcdf_integer_attr = val

end function get_netcdf_integer_attr

!-------------------------------------------------------

! set a global string attribute from a netcdf file

subroutine set_netcdf_string_attr(ncid, varname, val, filename)

integer,          intent(in) :: ncid
character(len=*), intent(in) :: varname
character(len=*), intent(in) :: val
character(len=*), intent(in) :: filename

integer :: rc

rc = nf90_put_att(ncid, NF90_GLOBAL, varname, val)
call nc_check( rc, 'set global string attribute ', varname //' to '//trim(val)//' in file '//trim(filename))


end subroutine set_netcdf_string_attr

!------------------------------------------------------------------

! write to both the logfile (assumes logfileunit is accessible and
! an open filehandle to the log) and to the stdout/console.
! THIS IS FOR DEBUGGING ONLY - if this is a message that the user
! should see and it should stay in the code long-term, call the 
! error_handler with E_MSG.  once we decide to remove the debugging,
! we can search for all instances of this call and remove it or
! convert it to using the error_handler.   p.s. using the error_handler
! means you don't have to do if (do_output()) because E_MSG already
! does that.

subroutine say(str)

character(len=*), intent(in) :: str

write(logfileunit, *) trim(str)
write(    *      , *) trim(str)

end subroutine say

!------------------------------------------------------------------

function get_grid_value(base_offset, ilon, ilat, ialt, x)

real(r8)             :: get_grid_value
integer, intent(in)  :: base_offset, ilon, ilat, ialt
real(r8), intent(in) :: x(:)

! Returns the value for the given lon,lat,alt point in the field that 
! starts at offset base_offset

integer :: offset

offset = (ilon - 1) + (ilat - 1) * ni + (ialt - 1) * (ni * nj)
get_grid_value = x(base_offset + offset)

end function get_grid_value


!------------------------------------------------------------------

! Read the grid dimensions from the restart netcdf file.
!
! The file name comes from module storage namelist.

subroutine get_grid_info(ncid)
   
integer,  intent(in)  :: ncid

! set module dimension information
! ni       Number of Longitude centers
! nj       Number of Latitude  centers
! nk       Number of Vertical grid centers
! nip1     Number of Longitude centers plus one
! njp1     Number of Latitude  centers plus one
! nkp1     Number of Vertical grid centers plus one

integer :: dimid

if ( .not. module_initialized ) call static_init_model()

! here's an ncdump of a restart file header:
!
! dimensions:
!         ni = 60 ;
!         nj = 60 ;
!         nk = 40 ;
!         nip1 = 61 ;
!         njp1 = 61 ;
!         nkp1 = 41 ;
!         time = 1 ;
!         nbudget = 10 ;
!         numq = 10 ;
! variables:
!         float time(time) ;
!                 time:long_name = "time since beginning of simulation" ;
!                 time:units = "seconds since 2000-07-03 00:00:00" ;
!         float xh(ni) ;
!                 xh:long_name = "west-east location of scalar grid points" ;
!                 xh:units = "m" ;
!         float xf(nip1) ;
!                 xf:long_name = "west-east location of staggered u grid points" ;
!                 xf:units = "m" ;
!         float yh(nj) ;
!                 yh:long_name = "south-north location of scalar grid points" ;
!                 yh:units = "m" ;
!         float yf(njp1) ;
!                 yf:long_name = "south-north location of staggered v grid points" ;
!                 yf:units = "m" ;
!         float zh(nk) ;
!                 zh:long_name = "nominal height of scalar grid points" ;
!                 zh:units = "m" ;
!         float zf(nkp1) ;
!                 zf:long_name = "nominal height of staggered w grid points" ;
!                 zf:units = "m" ;

! read the scalar grid points 
call nc_check( nf90_inq_dimid(ncid, 'ni', dimid=dimID), &
              'get_grid_info', 'inquire ni ')

call nc_check( nf90_inquire_dimension(ncid, dimID, len=ni), &
               'get_grid_info', 'inq_dimid ni ')

call nc_check( nf90_inq_dimid(ncid, 'nj', dimid=dimID), &
              'get_grid_info', 'inquire nj ')

call nc_check( nf90_inquire_dimension(ncid, dimID, len=nj), &
               'get_grid_info', 'inq_dimid nj ')

call nc_check( nf90_inq_dimid(ncid, 'nk', dimid=dimID), &
              'get_grid_info', 'inquire nk ')

call nc_check( nf90_inquire_dimension(ncid, dimID, len=nk), &
               'get_grid_info', 'inq_dimid nk ')

! read in the staggered grid points
call nc_check( nf90_inq_dimid(ncid, 'nip1', dimid=dimID), &
              'get_grid_info', 'inquire nip1 ')

call nc_check( nf90_inquire_dimension(ncid, dimID, len=nip1), &
               'get_grid_info', 'inq_dimid nip1 ')

call nc_check( nf90_inq_dimid(ncid, 'njp1', dimid=dimID), &
              'get_grid_info', 'inquire njp1 ')

call nc_check( nf90_inquire_dimension(ncid, dimID, len=njp1), &
               'get_grid_info', 'inq_dimid njp1 ')

call nc_check( nf90_inq_dimid(ncid, 'nkp1', dimid=dimID), &
              'get_grid_info', 'inquire nkp1 ')

call nc_check( nf90_inquire_dimension(ncid, dimID, len=nkp1), &
               'get_grid_info', 'inq_dimid nkp1 ')

end subroutine get_grid_info


!------------------------------------------------------------------

! read in the grid information
! these arrays are marked in units of 'm' == meters

subroutine get_grid(ncid)

integer,          intent(in)    :: ncid

! These module globals are set in this module
!  xh(:)        - west-east location of scalar grid points
!  yh(:)        - south-north location of scalar grid points
!  zh(:)        - nominal height of scalar grid points
!  xf(:)        - west-east location of staggered u grid points
!  yf(:)        - south-north location of staggered v grid points
!  zf(:)        - nominal height of staggered w grid points
!  zs(:,:)      - terrain height
!  zhalf(:,:,:) - height of half (scalar) grid points (3d array) 
!  zfull(:,:,:) - height of full (w) grid points (3d array)

integer :: VarID ! netcdf variable id
integer :: ret ! netcdf return code

! allocate module storage for grid information
allocate( xh( ni )) ! west-east location of scalar grid points
allocate( yh( nj )) ! south-north location of scalar grid points
allocate( zh( nk )) ! nominal height of scalar grid points

allocate( xf( nip1 )) ! west-east location of staggered u grid points
allocate( yf( njp1 )) ! south-north location of staggered v grid points
allocate( zf( nkp1 )) ! nominal height of staggered w grid points

allocate(    zs( ni, nj ))       ! terrain height
allocate( zhalf( ni, nj, nk ))   ! height of half (scalar) grid points (3d array) 
allocate( zfull( ni, nj, nkp1 )) ! height of full (w) grid points (3d array)

! grab scalar grid points
call nc_check( nf90_inq_varid(ncid, 'xh', VarID), &
              'get_grid', 'inquire xh ')

call nc_check( nf90_get_var(ncid, VarID, xh), &
              'get_grid', 'get_var xh ')

call nc_check( nf90_inq_varid(ncid, 'yh', VarID), &
              'get_grid', 'inquire yh ')

call nc_check( nf90_get_var(ncid, VarID, yh), &
              'get_grid', 'get_var yh ')

call nc_check( nf90_inq_varid(ncid, 'zh', VarID), &
              'get_grid', 'inquire zh ')

call nc_check( nf90_get_var(ncid, VarID, zh), &
              'get_grid', 'get_var zh ')

! grab staggared grid points
call nc_check( nf90_inq_varid(ncid, 'xf', VarID), &
              'get_grid', 'inquire xf ')

call nc_check( nf90_get_var(ncid, VarID, xf), &
              'get_grid', 'get_var xf ')


call nc_check( nf90_inq_varid(ncid, 'yf', VarID), &
              'get_grid', 'inquire yf ')

call nc_check( nf90_get_var(ncid, VarID, yf), &
              'get_grid', 'get_var yf ')

call nc_check( nf90_inq_varid(ncid, 'zf', VarID), &
              'get_grid', 'inquire zf ')

call nc_check( nf90_get_var(ncid, VarID, zf), &
              'get_grid', 'get_var zf ')

! grab 3d array of grid points
ret = nf90_inq_varid(ncid, 'zhalf', VarID)
if (ret == NF90_NOERR ) then
   call nc_check( nf90_inq_varid(ncid, 'zhalf', VarID), &
                 'get_grid', 'inquire zhalf ')
   
   call nc_check( nf90_get_var(ncid, VarID, zhalf), &
                 'get_grid', 'get_var zhalf ')
else
   string1 = 'zhalf not found and we do not know how to calculate it.'
   call error_handler(E_ERR,'get_grid',string1,source,revision,revdate)

   call nc_check( nf90_inq_varid(ncid, 'zs', VarID), &
                 'get_grid', 'inquire zs to calculate zhalf')
   
   call nc_check( nf90_get_var(ncid, VarID, zs), &
                 'get_grid', 'get_var zs to calculate zhalf')

   ! calculate zhalf from grid values
   ! algorithm is in init_terrain.F ... need sigma, zt
   !           zh(i,j,k)=zs(i,j)+sigma(k)*(zt-zs(i,j))/zt

endif

ret = nf90_inq_varid(ncid, 'zfull', VarID)
if (ret == NF90_NOERR ) then
   call nc_check( nf90_inq_varid(ncid, 'zfull', VarID), &
                 'get_grid', 'inquire zfull ')
   
   call nc_check( nf90_get_var(ncid, VarID, zfull), &
                 'get_grid', 'get_var zfull ')
else
   string1 = 'zfull not found and we do not know how to calculate it.'
   call error_handler(E_ERR,'get_grid',string1,source,revision,revdate)

   call nc_check( nf90_inq_varid(ncid, 'zs', VarID), &
                 'get_grid', 'inquire zs to calculate zfull ')
   
   call nc_check( nf90_get_var(ncid, VarID, zs), &
                 'get_grid', 'get_var zs to calculate zfull')

   ! calculate zfull from grid values
   ! algorithm is in init_terrain.F ... need sigmaf, zt
   !           zf(i,j,k)=zs(i,j)+sigmaf(k)*(zt-zs(i,j))/zt
endif

if ((debug > 0) .and. do_output()) then ! A little sanity check
   write(*,*)'xh    range ',minval(xh),maxval(xh)
   write(*,*)'yh    range ',minval(yh),maxval(yh)
   write(*,*)'zh    range ',minval(zh),maxval(zh)

   write(*,*)'xf    range ',minval(xf),maxval(xf)
   write(*,*)'yf    range ',minval(yf),maxval(yf)
   write(*,*)'zf    range ',minval(zf),maxval(zf)

   write(*,*)'zs    range ',minval(zs),maxval(zs)
   write(*,*)'zhalf range ',minval(zhalf),maxval(zhalf)
   write(*,*)'zfull range ',minval(zfull),maxval(zfull)
endif

end subroutine get_grid

!------------------------------------------------------------------

! static_init_model ensures that the model namelists are read.

function set_model_time_step()

type(time_type) :: set_model_time_step

if ( .not. module_initialized ) call static_init_model()

! Model dynamical timestep is namelist.input param1  dtl
!> @todo
! FIXME should we add the test we have done in other models
! where we enforce that this time is an even multiple of the
! internal model time step? i'm voting no for now, because
! george says if they don't divide evenly that CM1 will stop 
! at the requested time by shortening the last step.

set_model_time_step = set_time(assimilation_period_seconds, assimilation_period_days)

end function set_model_time_step

!------------------------------------------------------------------
!-----------------------------------------------------------------------
!>
!> Fill the array of requested variables, dart kinds, possible min/max
!> values and whether or not to update the field in the output file.
!>
!>@param state_variables the list of variables and kinds from model_mod_nml
!>@param ngood the number of variable/KIND pairs specified

subroutine parse_variable_input( state_variables, ngood )

character(len=*), intent(in)  :: state_variables(:)
integer,          intent(out) :: ngood

integer :: i
character(len=NF90_MAX_NAME) :: varname       ! column 1
character(len=NF90_MAX_NAME) :: dartstr       ! column 2
character(len=NF90_MAX_NAME) :: minvalstring  ! column 3
character(len=NF90_MAX_NAME) :: maxvalstring  ! column 4
character(len=NF90_MAX_NAME) :: state_or_aux  ! column 5   change to updateable

ngood = 0
MyLoop : do i = 1, MAX_STATE_VARIABLES

   varname      = trim(state_variables(num_state_table_columns*i-4))
   dartstr      = trim(state_variables(num_state_table_columns*i-3))
   minvalstring = trim(state_variables(num_state_table_columns*i-2))
   maxvalstring = trim(state_variables(num_state_table_columns*i-1))
   state_or_aux = trim(state_variables(num_state_table_columns*i  ))

   if ( varname == ' ' .and. dartstr == ' ' ) exit MyLoop ! Found end of list.

   if ( varname == ' ' .or. dartstr == ' ' ) then
      string1 = 'model_nml:model "variables" not fully specified'
      call error_handler(E_ERR,'parse_variable_input:',string1,source,revision,revdate)
   endif

   ! Make sure DART kind is valid

   if( get_raw_obs_kind_index(dartstr) < 0 ) then
      write(string1,'(''there is no obs_kind <'',a,''> in obs_kind_mod.f90'')') trim(dartstr)
      call error_handler(E_ERR,'parse_variable_input:',string1,source,revision,revdate)
   endif

   call to_upper(minvalstring)
   call to_upper(maxvalstring)
   call to_upper(state_or_aux)

   var_names(   i) = varname
   kind_list(   i) = get_raw_obs_kind_index(dartstr)
   clamp_vals(i,1) = string_to_real(minvalstring)
   clamp_vals(i,2) = string_to_real(maxvalstring)
   update_list( i) = string_to_logical(state_or_aux, 'NO_UPDATE')

   ngood = ngood + 1

enddo MyLoop

if (ngood == MAX_STATE_VARIABLES) then
   string1 = 'WARNING: There is a possibility you need to increase ''MAX_STATE_VARIABLES'''
   write(string2,'(''WARNING: you have specified at least '',i4,'' perhaps more.'')')ngood
   call error_handler(E_MSG,'parse_variable_input:',string1,source,revision,revdate,text2=string2)
endif

end subroutine parse_variable_input


!===================================================================
! End of model_mod
!===================================================================

end module model_mod

! <next few lines under version control, do not edit>
! $URL$
! $Id$
! $Revision$
! $Date$
