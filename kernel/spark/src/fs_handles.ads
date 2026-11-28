--  SPDX-License-Identifier: GPL-3.0-or-later
--  Manejadores abiertos de cada cliente del servidor de archivos (Hito 39).
--
--  El kernel le dice al servidor quién le llama: la marca (Badge) de la
--  capability con que el cliente envió, que solo pone el kernel (Cap_Core,
--  Lemma_Badges_Kept). Aquí el servidor guarda, por cada marca, una fila
--  con los manejadores que ese cliente tiene abiertos: un manejador es un
--  número pequeño (como un descriptor de archivo de Linux) que el cliente
--  recibe al buscar o crear, usa al leer, escribir, borrar, renombrar o
--  listar, y suelta con Close. Cada manejador abierto guarda la entrada y
--  la generación (Fs_Core) que nombra; Fs_Core sigue comprobando en cada uso
--  que valen (Opened), así que un manejador de algo borrado contesta Stale.
--
--  Teoremas:
--    Resolve solo contesta Ok con lo que el mismo cliente (la misma marca)
--      tiene abierto en ese manejador (Holds).
--    Cada operación es un paso Only_Client: solo cambia la fila de la marca
--      que la pide, o una libre que pasa a ser suya.
--    Lemma_Only_Owner: en cualquier historia de pasos así, si al final un
--      cliente tiene abierto algo que al principio no tenía en ese
--      manejador, lo abrió una petición con su marca. Un cliente no puede
--      usar, ni cambiar, ni cerrar los manejadores de otro.
--
--  Como Fs_Core, sin estado global: la tabla es del servidor y va por
--  referencia. Table_Ok es la condición que el servidor mantiene entre
--  llamadas (la establece Clear y cada operación la conserva).

pragma Unevaluated_Use_Of_Old (Allow);

with Fs_Core; use Fs_Core;

package Fs_Handles with
  SPARK_Mode
is
   Max_Clients : constant := 4;
   Max_Open    : constant := 16;

   --  Un manejador que este cliente no tiene abierto.
   Status_Bad_Handle : constant U64 := 12;
   --  Una petición sin marca: no se sabe de qué cliente es.
   Status_Denied     : constant U64 := 13;
   --  No quedan manejadores libres en la fila del cliente, o filas libres.
   Status_Handles    : constant U64 := 14;

   type Client_Index is range 0 .. Max_Clients - 1;
   type Open_Index is range 0 .. Max_Open - 1;

   type Open_Record is record
      Used : U32;
      File : U32;
      Gen  : U32;
      Pad  : U32;
   end record with
     Convention => C, Size => 128;
   for Open_Record use record
      Used at 0 range 0 .. 31;
      File at 4 range 0 .. 31;
      Gen  at 8 range 0 .. 31;
      Pad  at 12 range 0 .. 31;
   end record;

   Closed : constant Open_Record := (Used => 0, File => 0, Gen => 0, Pad => 0);

   type Open_Array is array (Open_Index) of Open_Record with
     Convention => C, Size => Max_Open * 128;

   type Client_Record is record
      Badge : U64;
      Opens : Open_Array;
   end record with
     Convention => C, Size => 64 + Max_Open * 128;
   for Client_Record use record
      Badge at 0 range 0 .. 63;
      Opens at 8 range 0 .. Max_Open * 128 - 1;
   end record;

   type Handle_Table is array (Client_Index) of Client_Record with
     Convention => C, Size => Max_Clients * (64 + Max_Open * 128);

   function Is_Open (R : Open_Record) return Boolean is (R.Used /= 0);

   --  Una fila libre (marca 0) no tiene nada abierto, y lo abierto nombra
   --  una entrada de la tabla.
   function Row_Ok (C : Client_Record) return Boolean is
     ((if C.Badge = 0
       then (for all H in Open_Index => not Is_Open (C.Opens (H))))
      and then
        (for all H in Open_Index =>
           (if Is_Open (C.Opens (H)) then C.Opens (H).File < Max_Files)));

   --  Una marca tiene a lo sumo una fila.
   function Badges_Unique (T : Handle_Table) return Boolean is
     (for all A in Client_Index =>
        (for all B in Client_Index =>
           (if A /= B and then T (A).Badge /= 0
            then T (A).Badge /= T (B).Badge)));

   function Table_Ok (T : Handle_Table) return Boolean is
     ((for all C in Client_Index => Row_Ok (T (C)))
      and then Badges_Unique (T));

   --  El cliente Badge tiene abierto el manejador Handle.
   function Is_Held (T : Handle_Table; Badge, Handle : U64) return Boolean is
     (Badge /= 0
      and then Handle < Max_Open
      and then
        (for some C in Client_Index =>
           T (C).Badge = Badge
           and then Is_Open (T (C).Opens (Open_Index (Handle)))));

   --  Y lo que tiene abierto en él es File con la generación Gen.
   function Holds (T : Handle_Table; Badge, Handle, File, Gen : U64) return Boolean is
     (Badge /= 0
      and then Handle < Max_Open
      and then
        (for some C in Client_Index =>
           T (C).Badge = Badge
           and then Is_Open (T (C).Opens (Open_Index (Handle)))
           and then U64 (T (C).Opens (Open_Index (Handle)).File) = File
           and then U64 (T (C).Opens (Open_Index (Handle)).Gen) = Gen));

   --  Lo que puede cambiar una petición del cliente Badge: su fila (que
   --  sigue siendo suya o queda libre), o una libre que pasa a ser suya.
   --  Sin marca no cambia nada.
   function Only_Client (Old, New_T : Handle_Table; Badge : U64) return Boolean is
     (for all C in Client_Index =>
        Old (C) = New_T (C)
        or else
          (Badge /= 0
           and then
             ((Old (C).Badge = Badge
               and then (New_T (C).Badge = Badge or else New_T (C).Badge = 0))
              or else (Old (C).Badge = 0 and then New_T (C).Badge = Badge))));

   --  Una historia de tablas y la marca de la petición de cada paso: B (K)
   --  es la de la que lleva de H (K) a H (K + 1).
   type History is array (Natural range <>) of Handle_Table with Ghost;
   type Badge_List is array (Natural range <>) of U64 with Ghost;

   function Steps_By (H : History; B : Badge_List) return Boolean is
     (H'First = B'First
      and then H'Last = B'Last
      and then
        (for all K in H'Range =>
           (if K < H'Last then Only_Client (H (K), H (K + 1), B (K)))))
   with Ghost;

   --  En un paso, lo que un cliente pasa a tener abierto lo abrió él.
   procedure Lemma_Step_Owner
     (Old, New_T : Handle_Table; Step, Badge, Handle, File, Gen : U64)
   with
     Ghost,
     Global => null,
     Pre    =>
       Only_Client (Old, New_T, Step)
       and then Holds (New_T, Badge, Handle, File, Gen)
       and then not Holds (Old, Badge, Handle, File, Gen),
     Post   => Step = Badge;

   --  En cualquier historia, si al final el cliente Badge tiene abierto en
   --  Handle algo que al principio no tenía ahí, alguno de los pasos fue
   --  una petición suya.
   procedure Lemma_Only_Owner
     (H : History; B : Badge_List; Badge, Handle, File, Gen : U64)
   with
     Ghost,
     Global => null,
     Pre    =>
       H'Length >= 1
       and then H'Last < Natural'Last
       and then Steps_By (H, B)
       and then Holds (H (H'Last), Badge, Handle, File, Gen)
       and then not Holds (H (H'First), Badge, Handle, File, Gen),
     Post   => (for some K in H'First .. H'Last - 1 => B (K) = Badge);

   --  Open encontrará un manejador libre: el cliente tiene fila y en ella
   --  uno libre, o no tiene fila y queda una libre.
   function Has_Room (T : Handle_Table; Badge : U64) return Boolean is
     (Badge /= 0
      and then
        ((for some C in Client_Index =>
            T (C).Badge = Badge
            and then (for some H in Open_Index => not Is_Open (T (C).Opens (H))))
         or else
           ((for all C in Client_Index => T (C).Badge /= Badge)
            and then (for some C in Client_Index => T (C).Badge = 0))));

   ------------------------------------------------------------------
   --  Operaciones (exportadas al servidor en Rust)
   ------------------------------------------------------------------

   --  Ningún cliente, nada abierto.
   procedure Clear (T : out Handle_Table)
   with
     Global        => null,
     Post          =>
       Table_Ok (T)
       and then (for all C in Client_Index => T (C).Badge = 0),
     Export,
     Convention    => C,
     External_Name => "fb_fs_handles_clear";

   --  1 si Open encontrará un manejador libre para el cliente Badge, 0 si no.
   --  El servidor lo pregunta antes de crear: si después no pudiera abrir lo
   --  creado, el cliente no sabría que existe.
   function Room (T : Handle_Table; Badge : U64) return U64
   with
     Global        => null,
     Pre           => Table_Ok (T),
     Post          => (Room'Result = 1) = Has_Room (T, Badge)
                      and then Room'Result <= 1,
     Export,
     Convention    => C,
     External_Name => "fb_fs_room";

   --  Abre File con la generación Gen para el cliente Badge, en el manejador
   --  libre más bajo de su fila (si no tiene fila, toma una libre).
   procedure Open
     (T : in out Handle_Table; Badge, File, Gen : U64;
      Handle : out U64; Status : out U64)
   with
     Global        => null,
     Pre           => Table_Ok (T),
     Post          =>
       Table_Ok (T)
       and then Only_Client (T'Old, T, Badge)
       and then
         (if Has_Room (T'Old, Badge)
            and then File < Max_Files
            and then Gen <= U64 (U32'Last)
          then Status = Status_Ok)
       and then
         (if Status = Status_Ok
          then Handle < Max_Open
            and then not Is_Held (T'Old, Badge, Handle)
            --  El libre más bajo, como un descriptor de archivo de Linux.
            and then
              (for all G in Open_Index =>
                 (if U64 (G) < Handle then Is_Held (T'Old, Badge, U64 (G))))
            and then Holds (T, Badge, Handle, File, Gen)
            --  Los demás manejadores, de este y de los demás clientes,
            --  siguen igual.
            and then
              (for all C in Client_Index =>
                 (for all H in Open_Index =>
                    (if U64 (H) /= Handle
                     then T (C).Opens (H) = T'Old (C).Opens (H))))
          else T = T'Old
            and then
              (if Badge = 0 then Status = Status_Denied
               elsif File >= Max_Files or else Gen > U64 (U32'Last)
               then Status = Status_Request
               else Status = Status_Handles)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_open";

   --  Lo que el cliente Badge tiene abierto en Handle.
   procedure Resolve
     (T : Handle_Table; Badge, Handle : U64; File, Gen, Status : out U64)
   with
     Global        => null,
     Pre           => Table_Ok (T),
     Post          =>
       (if Status = Status_Ok
        then Holds (T, Badge, Handle, File, Gen) and then File < Max_Files
        else not Is_Held (T, Badge, Handle)
          and then
            (if Badge = 0 then Status = Status_Denied
             else Status = Status_Bad_Handle)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_resolve";

   --  El cliente Badge suelta Handle. Lo demás queda igual.
   procedure Close
     (T : in out Handle_Table; Badge, Handle : U64; Status : out U64)
   with
     Global        => null,
     Pre           => Table_Ok (T),
     Post          =>
       Table_Ok (T)
       and then Only_Client (T'Old, T, Badge)
       and then not Is_Held (T, Badge, Handle)
       and then
         (for all C in Client_Index =>
            T (C).Badge = T'Old (C).Badge
            and then
              (for all H in Open_Index =>
                 (if U64 (H) /= Handle
                  then T (C).Opens (H) = T'Old (C).Opens (H))))
       and then
         (if Status = Status_Ok
          then Is_Held (T'Old, Badge, Handle)
          else T = T'Old
            and then
              (if Badge = 0 then Status = Status_Denied
               else Status = Status_Bad_Handle)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_close";

   --  El cliente Badge se despide: suelta todo y su fila queda libre.
   procedure Detach (T : in out Handle_Table; Badge : U64)
   with
     Global        => null,
     Pre           => Table_Ok (T),
     Post          =>
       Table_Ok (T)
       and then Only_Client (T'Old, T, Badge)
       and then
         (if Badge /= 0
          then (for all C in Client_Index => T (C).Badge /= Badge)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_detach";

end Fs_Handles;
