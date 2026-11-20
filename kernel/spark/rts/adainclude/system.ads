--  Runtime Ada propio de Fabianus: solo la descripción del objetivo que exige
--  el compilador GNAT. Es una especificación pura y no genera código.

package System with
  Pure,
  No_Elaboration_Code_All
is
   type Name is (SYSTEM_NAME_GNAT);
   System_Name : constant Name := SYSTEM_NAME_GNAT;

   Min_Int : constant := -2**(Standard'Max_Integer_Size - 1);
   Max_Int : constant := 2**(Standard'Max_Integer_Size - 1) - 1;

   Max_Binary_Modulus    : constant := 2**Standard'Max_Integer_Size;
   Max_Nonbinary_Modulus : constant := 2**Integer'Size - 1;

   Max_Base_Digits : constant := Long_Long_Float'Digits;
   Max_Digits      : constant := Long_Long_Float'Digits;
   Max_Mantissa    : constant := Standard'Max_Integer_Size - 1;
   Fine_Delta      : constant := 2.0**(-Max_Mantissa);
   Tick            : constant := 0.0;

   type Address is private with Preelaborable_Initialization;
   Null_Address : constant Address;

   Storage_Unit : constant := 8;
   Word_Size    : constant := Standard'Word_Size;
   Memory_Size  : constant := 2**Word_Size;

   function "<"  (Left, Right : Address) return Boolean with Import, Convention => Intrinsic;
   function "<=" (Left, Right : Address) return Boolean with Import, Convention => Intrinsic;
   function ">"  (Left, Right : Address) return Boolean with Import, Convention => Intrinsic;
   function ">=" (Left, Right : Address) return Boolean with Import, Convention => Intrinsic;
   function "="  (Left, Right : Address) return Boolean with Import, Convention => Intrinsic;

   type Bit_Order is (High_Order_First, Low_Order_First);
   Default_Bit_Order : constant Bit_Order := Low_Order_First;

   Max_Priority           : constant Positive := 30;
   Max_Interrupt_Priority : constant Positive := 31;

   subtype Any_Priority       is Integer      range 0 .. 31;
   subtype Priority           is Any_Priority range 0 .. 30;
   subtype Interrupt_Priority is Any_Priority range 31 .. 31;

   Default_Priority : constant Priority := 15;

private

   type Address is mod Memory_Size with Size => Standard'Address_Size;
   Null_Address : constant Address := 0;

   Atomic_Sync_Default       : constant Boolean := False;
   Backend_Divide_Checks     : constant Boolean := False;
   Backend_Overflow_Checks   : constant Boolean := True;
   Command_Line_Args         : constant Boolean := False;
   Configurable_Run_Time     : constant Boolean := True;
   Denorm                    : constant Boolean := True;
   Duration_32_Bits          : constant Boolean := False;
   Exit_Status_Supported     : constant Boolean := False;
   Machine_Overflows         : constant Boolean := False;
   Machine_Rounds            : constant Boolean := True;
   Preallocated_Stacks       : constant Boolean := False;
   Signed_Zeros              : constant Boolean := True;
   Stack_Check_Default       : constant Boolean := False;
   Stack_Check_Probes        : constant Boolean := False;
   Stack_Check_Limits        : constant Boolean := False;
   Support_Aggregates        : constant Boolean := True;
   Support_Atomic_Primitives : constant Boolean := True;
   Support_Composite_Assign  : constant Boolean := True;
   Support_Composite_Compare : constant Boolean := True;
   Support_Long_Shifts       : constant Boolean := True;
   Always_Compatible_Rep     : constant Boolean := True;
   Suppress_Standard_Library : constant Boolean := True;
   Use_Ada_Main_Program_Name : constant Boolean := False;
   ZCX_By_Default            : constant Boolean := True;

end System;
