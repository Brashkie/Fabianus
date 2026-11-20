--  Núcleo demostrado de las tablas de páginas Sv39 del kernel.
--
--  Invariante demostrada (Well_Formed), que vale tras cada operación:
--    * Toda entrada es nula, una hoja o un puntero a tabla, sin bits reservados.
--    * Ninguna hoja es a la vez escribible y ejecutable (W^X).
--    * Ninguna hoja es accesible desde modo usuario.
--    * Un puntero siempre apunta a una tabla ya reservada y de índice mayor que
--      la tabla que lo contiene, así que la estructura no puede tener ciclos.
--    * Las tablas sin reservar están enteramente a cero.

package Page_Tree with
  SPARK_Mode,
  Preelaborate
is
   type U64 is mod 2**64 with Size => 64;

   Max_Tables : constant := 16;

   type Table_Total is range 0 .. Max_Tables;
   subtype Table_Id is Table_Total range 0 .. Max_Tables - 1;
   type Entry_Index is range 0 .. 511;
   type Level is range 0 .. 2;

   type Page_Table is array (Entry_Index) of U64;
   type Table_Pool is array (Table_Id) of Page_Table;

   --  W^X por construcción: no existe forma de pedir escritura y ejecución.
   type Permission is (Read_Only, Read_Write, Read_Execute);
   type Page_Size is (Size_4K, Size_2M);
   type Status is (Ok, No_Space, Conflict);

   Max_Virtual  : constant U64 := 2**39;
   Max_Ppn      : constant U64 := 2**44;
   Max_Base_Ppn : constant U64 := 2**43;

   Flag_V : constant U64 := 1;
   Flag_R : constant U64 := 2;
   Flag_W : constant U64 := 4;
   Flag_X : constant U64 := 8;
   Flag_U : constant U64 := 16;
   Flag_G : constant U64 := 32;
   Flag_A : constant U64 := 64;
   Flag_D : constant U64 := 128;

   Low_Flags_Mask : constant U64 := 1023;

   function Ppn_Of (E : U64) return U64 is (E / 1024);

   function Table_Entry (Ppn : U64) return U64 is (Ppn * 1024 + Flag_V) with
     Pre => Ppn < Max_Ppn;

   function Leaf_Entry (Ppn : U64; Perm : Permission) return U64 is
     (Ppn * 1024 + Flag_V + Flag_R + Flag_G + Flag_A
      + (case Perm is
           when Read_Only    => 0,
           when Read_Write   => Flag_W + Flag_D,
           when Read_Execute => Flag_X))
   with Pre => Ppn < Max_Ppn;

   function Is_Table (E : U64) return Boolean is
     ((E and Low_Flags_Mask) = Flag_V);

   function Is_Leaf (E : U64) return Boolean is
     ((E and Flag_V) /= 0
      and then (E and Flag_R) /= 0
      and then (E and Flag_U) = 0
      and then (E and (Flag_W or Flag_X)) /= (Flag_W or Flag_X));

   function Entry_Ok
     (E    : U64;
      Base : U64;
      T    : Table_Id;
      Used : Table_Total) return Boolean
   is
     (E = 0
      or else
        (E < 2**54
         and then
           (Is_Leaf (E)
            or else
              (Is_Table (E)
               and then Ppn_Of (E) >= Base + U64 (T) + 1
               and then Ppn_Of (E) + 1 <= Base + U64 (Used)))))
   with
     Ghost,
     Pre => Base <= Max_Base_Ppn;

   function Well_Formed
     (Pool : Table_Pool;
      Base : U64;
      Used : Table_Total) return Boolean
   is
     (for all T in Table_Id =>
        (for all I in Entry_Index =>
           (if T < Used
            then Entry_Ok (Pool (T) (I), Base, T, Used)
            else Pool (T) (I) = 0)))
   with
     Ghost,
     Pre => Base <= Max_Base_Ppn;

   --  Índice de la dirección virtual en el nivel indicado.
   function Vpn (Va : U64; L : Level) return Entry_Index;

   --  Una entrada que apunta a una tabla del conjunto.
   function Points_Inside (E : U64; Base : U64) return Boolean is
     (Is_Table (E)
      and then Ppn_Of (E) >= Base
      and then Ppn_Of (E) - Base < U64 (Max_Tables))
   with Ghost;

   function Child_Of (E : U64; Base : U64) return Table_Id is
     (Table_Id (Ppn_Of (E) - Base))
   with
     Ghost,
     Pre => Points_Inside (E, Base);

   --  Modelo del recorrido que hace el hardware: la entrada final de una
   --  dirección, o 0 si el camino no existe.
   function Lookup
     (Pool : Table_Pool;
      Base : U64;
      Va   : U64;
      Size : Page_Size) return U64
   is
     (if not Points_Inside (Pool (0) (Vpn (Va, 2)), Base)
      then 0
      elsif Size = Size_2M
      then Pool (Child_Of (Pool (0) (Vpn (Va, 2)), Base)) (Vpn (Va, 1))
      elsif not Points_Inside
                  (Pool (Child_Of (Pool (0) (Vpn (Va, 2)), Base)) (Vpn (Va, 1)),
                   Base)
      then 0
      else Pool
             (Child_Of
                (Pool (Child_Of (Pool (0) (Vpn (Va, 2)), Base)) (Vpn (Va, 1)),
                 Base))
             (Vpn (Va, 0)))
   with Ghost;

   --  Solo se han rellenado entradas vacías: nada existente ha cambiado.
   function Only_Fills (Before, After : Table_Pool) return Boolean is
     (for all T in Table_Id =>
        (for all I in Entry_Index =>
           (if Before (T) (I) /= 0 then After (T) (I) = Before (T) (I))))
   with Ghost;

   --  Instala una traducción sin pisar jamás una que ya exista.
   procedure Map_Page
     (Pool   : in out Table_Pool;
      Used   : in out Table_Total;
      Base   : U64;
      Va     : U64;
      Ppn    : U64;
      Perm   : Permission;
      Size   : Page_Size;
      Result : out Status)
   with
     Pre  =>
       Base <= Max_Base_Ppn
       and then Used >= 1
       and then Va < Max_Virtual
       and then Ppn < Max_Ppn
       and then Well_Formed (Pool, Base, Used),
     Post =>
       Used >= Used'Old
       and then Well_Formed (Pool, Base, Used)
       and then Only_Fills (Pool'Old, Pool)
       and then
         (if Result = Ok
          then Lookup (Pool, Base, Va, Size) = Leaf_Entry (Ppn, Perm));

end Page_Tree;
