--  SPDX-License-Identifier: GPL-3.0-or-later
--  Núcleo demostrado del sistema de archivos de Fabianus.
--
--  Formato (bloques de 4 KiB):
--    bloque 0: superbloque (número mágico, versión, bloques, entradas);
--    bloque 1: la tabla, 64 entradas de 64 bytes;
--    bloques 2 .. 255: datos.
--  Cada entrada es un archivo o un directorio, con un nombre de hasta 20
--  bytes y el directorio que la contiene (Parent: otra entrada, o Root_Dir
--  para la raíz, que no ocupa entrada). Un archivo tiene una longitud en
--  bytes y hasta 16 bloques; un directorio no tiene bloques: sus hijos son
--  las entradas que lo nombran como Parent. Así crear, borrar y renombrar,
--  también entre directorios, cambian una sola entrada.
--  Cada entrada tiene además una generación (Gen), que sube al borrarla. Un
--  manejador es una entrada y una generación: vale mientras la entrada siga
--  en uso con esa generación (Opened). Una entrada cuya generación llega a
--  Gen_Last queda retirada: no se vuelve a usar.
--  No hay mapa de bloques en el disco: el de memoria (Owner) se deduce de la
--  tabla al montar, igual que la profundidad de cada entrada (Depth).
--
--  Teoremas:
--    Lemma_Disjoint: ningún bloque pertenece a dos archivos, ni dos veces al
--      mismo, ni es de los metadatos.
--    Lemma_No_Cycle: subiendo de directorio en directorio nunca se vuelve a
--      la entrada de partida. La profundidad baja exactamente uno en cada
--      paso (Depths_Ok), y un número natural no puede bajar para siempre:
--      toda entrada cuelga de la raíz.
--    Lemma_Same_Object: cada operación da un paso Step_Ok (ninguna
--      generación baja, y una entrada solo deja de estar en uso si la suya
--      sube). En cualquier historia de pasos así, si un manejador vale al
--      principio y al final, valió en todos los pasos intermedios: la
--      entrada nunca se borró, así que es el mismo objeto. Un manejador de
--      algo borrado no vuelve a valer nunca.
--  En un mismo directorio no hay dos nombres iguales. Mount solo acepta una
--  tabla así, y cada operación la conserva.
--
--  No hay estado global: el servidor de archivos es un proceso de usuario
--  cuya imagen es de solo lectura. La tabla y los mapas son suyos y se pasan
--  por referencia; Valid es la condición que el servidor mantiene entre
--  llamadas (la establece Mount o Format, y cada operación la conserva).
--  Todo argumento que viene de un cliente se comprueba aquí y se contesta con
--  un estado.

pragma Unevaluated_Use_Of_Old (Allow);

package Fs_Core with
  SPARK_Mode
is
   type U64 is mod 2**64 with Size => 64;
   type U32 is mod 2**32 with Size => 32;
   type U16 is mod 2**16 with Size => 16;
   type U8 is mod 2**8 with Size => 8;

   Block_Bytes  : constant := 4096;
   Max_Blocks   : constant := 256;
   Max_Files    : constant := 64;
   File_Blocks  : constant := 16;
   Name_Bytes   : constant := 20;
   First_Data   : constant := 2;
   Max_Length   : constant := File_Blocks * Block_Bytes;
   Max_Depth    : constant := Max_Files;

   --  La generación de una entrada retirada.
   Gen_Last : constant U32 := U32'Last;

   Magic   : constant U64 := 16#5346_5355_4E41_4246#;  --  "FBANUSFS"
   Version : constant U32 := 3;

   --  El directorio raíz, en Parent y en las peticiones.
   Root_Dir  : constant := 255;
   Kind_File : constant := 0;
   Kind_Dir  : constant := 1;

   Slash : constant U8 := 16#2F#;
   Dot   : constant U8 := 16#2E#;

   Status_Ok        : constant U64 := 0;
   Status_Request   : constant U64 := 1;
   Status_Not_Found : constant U64 := 3;
   Status_Exists    : constant U64 := 4;
   Status_Full      : constant U64 := 5;
   Status_Unformatted : constant U64 := 6;
   Status_Corrupt   : constant U64 := 7;
   Status_Not_Dir   : constant U64 := 8;
   Status_Not_Empty : constant U64 := 9;
   Status_Is_Dir    : constant U64 := 10;
   Status_Stale     : constant U64 := 11;

   type Block_Index is range 0 .. Max_Blocks - 1;
   subtype Data_Block is Block_Index range First_Data .. Block_Index'Last;
   type File_Index is range 0 .. Max_Files - 1;
   type Slot_Index is range 0 .. File_Blocks - 1;
   subtype Block_Count is Integer range 0 .. File_Blocks;

   type Name_Array is array (0 .. Name_Bytes - 1) of U8 with
     Convention => C;
   type Block_List is array (Slot_Index) of U16 with
     Convention => C;

   --  Una entrada de la tabla tal como está en el disco: cualquier patrón de
   --  bits es un valor posible, y Mount decide si la tabla es válida.
   type Entry_Record is record
      Used   : U8;
      Kind   : U8;
      Parent : U8;
      Pad    : U8;
      Length : U32;
      Gen    : U32;
      Name   : Name_Array;
      Blocks : Block_List;
   end record with
     Convention => C, Size => 512;
   for Entry_Record use record
      Used   at 0 range 0 .. 7;
      Kind   at 1 range 0 .. 7;
      Parent at 2 range 0 .. 7;
      Pad    at 3 range 0 .. 7;
      Length at 4 range 0 .. 31;
      Gen    at 8 range 0 .. 31;
      Name   at 12 range 0 .. 159;
      Blocks at 32 range 0 .. 255;
   end record;

   type Table is array (File_Index) of Entry_Record with
     Convention => C, Size => Max_Files * 512;

   type Super_Record is record
      Magic   : U64;
      Version : U32;
      Blocks  : U32;
      Files   : U32;
      Unused  : U32;
   end record with
     Convention => C, Size => 192;
   for Super_Record use record
      Magic   at 0 range 0 .. 63;
      Version at 8 range 0 .. 31;
      Blocks  at 12 range 0 .. 31;
      Files   at 16 range 0 .. 31;
      Unused  at 20 range 0 .. 31;
   end record;

   --  De quién es cada bloque, en memoria: Used = 0 si de nadie; si no,
   --  del archivo File, en su posición Slot.
   type Owner_Record is record
      Used : U8;
      File : U8;
      Slot : U8;
      Pad  : U8;
   end record with
     Convention => C, Size => 32;
   for Owner_Record use record
      Used at 0 range 0 .. 7;
      File at 1 range 0 .. 7;
      Slot at 2 range 0 .. 7;
      Pad  at 3 range 0 .. 7;
   end record;

   type Owner_Map is array (Block_Index) of Owner_Record with
     Convention => C;

   --  Profundidad de cada entrada, en memoria: 1 para las de la raíz, la de
   --  su directorio más uno para las demás, 0 si la entrada está libre.
   type Depth_Map is array (File_Index) of U8 with
     Convention => C;

   ------------------------------------------------------------------
   --  Especificación
   ------------------------------------------------------------------

   --  Las propiedades de una entrada dependen solo de ella: así, cambiar
   --  una entrada no obliga a razonar de nuevo sobre las demás.
   function Is_Used (E : Entry_Record) return Boolean is
     (E.Used = 1);

   function Is_Dir (E : Entry_Record) return Boolean is
     (E.Kind = Kind_Dir);

   function At_Root (E : Entry_Record) return Boolean is
     (E.Parent = Root_Dir);

   --  Bloques que ocupa un archivo de Length bytes.
   function Count_Of (Length : U32) return Block_Count is
     (if Length > Max_Length then 0
      else Block_Count ((Length + (Block_Bytes - 1)) / Block_Bytes));

   function Count (E : Entry_Record) return Block_Count is
     (Count_Of (E.Length));

   function In_File (E : Entry_Record; S : Slot_Index) return Boolean is
     (Is_Used (E) and then Integer (S) < Count (E));

   function Is_Data (Value : U16) return Boolean is
     (Value >= First_Data and then Value < Max_Blocks);

   function Owned (O : Owner_Map; B : Block_Index) return Boolean is
     (O (B).Used /= 0);

   function Owner_Is
     (O : Owner_Map; B : Block_Index; F : File_Index; S : Slot_Index)
      return Boolean
   is (O (B).Used = 1
       and then O (B).File = U8 (F)
       and then O (B).Slot = U8 (S));

   --  Un nombre: no vacío, sin '/', rellenado con ceros tras el final (un
   --  solo modo de escribir cada nombre) y distinto de "." y "..".
   function Name_Ok (N : Name_Array) return Boolean is
     (N (0) /= 0
      and then (for all I in Name_Array'Range => N (I) /= Slash)
      and then
        (for all I in 1 .. Name_Bytes - 1 => (if N (I - 1) = 0 then N (I) = 0))
      and then not (N (0) = Dot and then N (1) = 0)
      and then not (N (0) = Dot and then N (1) = Dot and then N (2) = 0));

   --  Cada entrada, sola: los valores tienen sentido.
   function Entry_Ok (E : Entry_Record) return Boolean is
     ((E.Used = 0 or else E.Used = 1)
      and then
        (if Is_Used (E)
         then (E.Kind = Kind_File or else E.Kind = Kind_Dir)
           and then E.Gen < Gen_Last
           and then (At_Root (E) or else E.Parent < Max_Files)
           and then E.Length <= Max_Length
           and then (if Is_Dir (E) then E.Length = 0)
           and then Name_Ok (E.Name)
           and then
             (for all S in Slot_Index =>
                (if Integer (S) < Count (E)
                 then Is_Data (E.Blocks (S))
                 else E.Blocks (S) = 0))));

   function Entries_Ok (T : Table) return Boolean is
     (for all F in File_Index => Entry_Ok (T (F)));

   --  Lo que dice la tabla es lo que dice el mapa, en los dos sentidos.
   function Table_To_Map (T : Table; O : Owner_Map) return Boolean is
     (for all F in File_Index =>
        (for all S in Slot_Index =>
           (if In_File (T (F), S)
            then Owner_Is (O, Block_Index (T (F).Blocks (S)), F, S))))
   with Pre => Entries_Ok (T);

   function Map_To_Table (T : Table; O : Owner_Map) return Boolean is
     (for all B in Block_Index =>
        (if Owned (O, B)
         then B >= First_Data
           and then O (B).Used = 1
           and then O (B).File < Max_Files
           and then O (B).Slot < File_Blocks
           and then In_File (T (File_Index (O (B).File)), Slot_Index (O (B).Slot))
           and then
             T (File_Index (O (B).File)).Blocks (Slot_Index (O (B).Slot))
             = U16 (B)));

   --  En un mismo directorio no hay dos nombres iguales.
   function Names_Unique (T : Table) return Boolean is
     (for all F in File_Index =>
        (for all G in File_Index =>
           (if F /= G and then Is_Used (T (F)) and then Is_Used (T (G))
              and then T (F).Parent = T (G).Parent
            then T (F).Name /= T (G).Name)));

   --  El directorio de cada entrada existe y es un directorio.
   function Parents_Ok (T : Table) return Boolean is
     (for all F in File_Index =>
        (if Is_Used (T (F)) and then not At_Root (T (F))
         then T (F).Parent < Max_Files
           and then Is_Used (T (File_Index (T (F).Parent)))
           and then Is_Dir (T (File_Index (T (F).Parent)))));

   --  La profundidad de una entrada es la de su directorio más uno.
   function Depth_Ok (T : Table; D : Depth_Map; F : File_Index) return Boolean is
     (if Is_Used (T (F))
      then D (F) >= 1
        and then D (F) <= Max_Depth
        and then
          (if At_Root (T (F)) then D (F) = 1
           else T (F).Parent < Max_Files
             and then
               Integer (D (F)) = Integer (D (File_Index (T (F).Parent))) + 1)
      else D (F) = 0);

   function Depths_Ok (T : Table; D : Depth_Map) return Boolean is
     (for all F in File_Index => Depth_Ok (T, D, F));

   function Valid (T : Table; O : Owner_Map; D : Depth_Map) return Boolean is
     (Entries_Ok (T)
      and then Table_To_Map (T, O)
      and then Map_To_Table (T, O)
      and then Names_Unique (T)
      and then Parents_Ok (T)
      and then Depths_Ok (T, D));

   function Super_Ok (Super : Super_Record) return Boolean is
     (Super.Magic = Magic
      and then Super.Version = Version
      and then Super.Blocks = Max_Blocks
      and then Super.Files = Max_Files);

   --  Un directorio al que se puede pedir algo: la raíz o una entrada en uso
   --  que es un directorio.
   function Dir_Ok (T : Table; Dir : U64) return Boolean is
     (Dir = Root_Dir
      or else
        (Dir < Max_Files
         and then Is_Used (T (File_Index (Dir)))
         and then Is_Dir (T (File_Index (Dir)))));

   --  Ningún archivo de la tabla usa el bloque B. Solo mira la tabla: es lo
   --  que vería quien montara el disco.
   function Not_In_Table (T : Table; B : U64) return Boolean is
     (for all F in File_Index =>
        (for all S in Slot_Index =>
           (if In_File (T (F), S) then U64 (T (F).Blocks (S)) /= B)));

   --  Una entrada cambiada solo en su directorio y su nombre.
   function Moved (Old, E : Entry_Record) return Boolean is
     (E.Used = Old.Used
      and then E.Kind = Old.Kind
      and then E.Gen = Old.Gen
      and then E.Length = Old.Length
      and then E.Blocks = Old.Blocks);

   --  Un bloque libre en el mapa no lo nombra la tabla.
   procedure Lemma_Free_Unnamed
     (T : Table; O : Owner_Map; D : Depth_Map; B : Block_Index)
   with
     Ghost,
     Global => null,
     Pre    => Valid (T, O, D) and then not Owned (O, B),
     Post   => Not_In_Table (T, U64 (B));

   --  Ningún bloque es de dos archivos, ni está dos veces en uno, ni es de
   --  los metadatos.
   procedure Lemma_Disjoint
     (T : Table; O : Owner_Map; D : Depth_Map; F, G : File_Index;
      S, R : Slot_Index)
   with
     Ghost,
     Global => null,
     Pre    =>
       Valid (T, O, D) and then In_File (T (F), S) and then In_File (T (G), R),
     Post   =>
       T (F).Blocks (S) >= First_Data
       and then
         (if T (F).Blocks (S) = T (G).Blocks (R) then F = G and then S = R);

   --  Una cadena de entradas en la que cada una es el directorio de la
   --  anterior: C (0), su directorio C (1), el de este C (2)...
   type Chain is array (0 .. Max_Files) of File_Index;
   subtype Chain_Length is Integer range 1 .. Max_Files;

   function Climbs (T : Table; C : Chain; K : Chain_Length) return Boolean is
     (for all I in 0 .. K - 1 =>
        Is_Used (T (C (I))) and then U64 (T (C (I)).Parent) = U64 (C (I + 1)));

   --  Subiendo nunca se vuelve a la entrada de partida: no hay ciclos.
   procedure Lemma_No_Cycle
     (T : Table; O : Owner_Map; D : Depth_Map; C : Chain; K : Chain_Length)
   with
     Ghost,
     Global => null,
     Pre    => Valid (T, O, D) and then Climbs (T, C, K),
     Post   => C (K) /= C (0);

   --  Manejadores.

   --  El manejador (File, Gen) vale: la entrada está en uso con esa
   --  generación.
   function Opened (T : Table; File, Gen : U64) return Boolean is
     (File < Max_Files
      and then Is_Used (T (File_Index (File)))
      and then U64 (T (File_Index (File)).Gen) = Gen);

   --  Un directorio por manejador: la raíz (Root_Dir con generación 0) o un
   --  manejador que vale de un directorio.
   function Dir_Opened (T : Table; Dir, Gen : U64) return Boolean is
     ((Dir = Root_Dir and then Gen = 0)
      or else (Opened (T, Dir, Gen) and then Is_Dir (T (File_Index (Dir)))));

   --  Lo que puede hacer una operación con la tabla: ninguna generación baja,
   --  una entrada en uso solo deja de estarlo si su generación sube, y
   --  mientras siga en uso con la misma generación no cambia de tipo.
   function Step_Ok (Old, T : Table) return Boolean is
     (for all F in File_Index =>
        T (F).Gen >= Old (F).Gen
        and then
          (if Is_Used (Old (F)) and then T (F).Gen = Old (F).Gen
           then Is_Used (T (F)) and then T (F).Kind = Old (F).Kind));

   --  Una sucesión de tablas, una tras cada operación.
   type History is array (Natural range <>) of Table with Ghost;

   function Steps_Ok (H : History) return Boolean is
     (for all K in H'Range =>
        (if K < H'Last then Step_Ok (H (K), H (K + 1))))
   with Ghost;

   --  Un manejador que vale al principio y al final de una historia valió en
   --  todos sus pasos, y la entrada no cambió de tipo: es el mismo objeto,
   --  que nunca se borró.
   procedure Lemma_Same_Object (H : History; File, Gen : U64)
   with
     Ghost,
     Global => null,
     Pre    =>
       H'Length >= 1
       and then Steps_Ok (H)
       and then Opened (H (H'First), File, Gen)
       and then Opened (H (H'Last), File, Gen),
     Post   =>
       (for all K in H'Range =>
          Opened (H (K), File, Gen)
          and then
            H (K) (File_Index (File)).Kind = H (H'First) (File_Index (File)).Kind);

   ------------------------------------------------------------------
   --  Operaciones (exportadas al servidor en Rust)
   ------------------------------------------------------------------

   --  Comprueba el superbloque y la tabla leídos del disco y construye los
   --  mapas. Sin superbloque válido, el disco no tiene formato; con él pero
   --  con la tabla mal (también con un ciclo de directorios), está corrupto.
   --  Un corte de luz nunca debe dejar un disco corrupto: la prueba de cortes
   --  lo comprueba.
   procedure Mount
     (Super : Super_Record; T : Table; O : out Owner_Map; D : out Depth_Map;
      Status : out U64)
   with
     Global        => null,
     Post          =>
       (if not Super_Ok (Super) then Status = Status_Unformatted
        else (Status = Status_Ok and then Valid (T, O, D))
          or else Status = Status_Corrupt),
     Export,
     Convention    => C,
     External_Name => "fb_fs_mount";

   --  Un sistema de archivos vacío. Con Keep /= 0 (la tabla de T es la de un
   --  sistema de archivos que pudo dar manejadores), cada generación sube
   --  uno, o se queda retirada: ningún manejador de antes vale después, como
   --  si se borrara todo. Sin Keep, todas empiezan en 0.
   procedure Format
     (Super : out Super_Record; T : in out Table; O : out Owner_Map;
      D : out Depth_Map; Keep : U64)
   with
     Global        => null,
     Post          =>
       Valid (T, O, D)
       and then (for all F in File_Index => not Is_Used (T (F)))
       and then Super_Ok (Super)
       and then
         (if Keep /= 0
          then
            (for all F in File_Index =>
               (if T'Old (F).Gen < Gen_Last
                then T (F).Gen = T'Old (F).Gen + 1
                else T (F).Gen = Gen_Last))
            and then (if Entries_Ok (T'Old) then Step_Ok (T'Old, T))
          else (for all F in File_Index => T (F).Gen = 0)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_format";

   --  La entrada con ese nombre en el directorio Dir.
   procedure Lookup
     (T : Table; O : Owner_Map; D : Depth_Map; Dir : U64; Name : Name_Array;
      File : out U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       (if Status = Status_Ok
        then Dir_Ok (T, Dir)
          and then File < Max_Files
          and then Is_Used (T (File_Index (File)))
          and then U64 (T (File_Index (File)).Parent) = Dir
          and then T (File_Index (File)).Name = Name
        elsif Status = Status_Not_Found
        then (Dir_Ok (T, Dir)
              and then
                (for all F in File_Index =>
                   (if Is_Used (T (F)) and then U64 (T (F).Parent) = Dir
                    then T (F).Name /= Name)))
          or else (Dir < Max_Files and then not Is_Used (T (File_Index (Dir))))
        else not Dir_Ok (T, Dir)
          and then (Status = Status_Not_Dir or else Status = Status_Request)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_lookup";

   --  Un archivo vacío o un directorio vacío nuevo, de tipo Kind, en Dir. La
   --  entrada nueva conserva la generación que tenía libre: nunca una
   --  retirada.
   procedure Create
     (T : in out Table; O : Owner_Map; D : in out Depth_Map; Dir : U64;
      Name : Name_Array; Kind : U64; File : out U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       Valid (T, O, D)
       and then Step_Ok (T'Old, T)
       and then
         (if Status = Status_Ok
          then Dir_Ok (T'Old, Dir)
            and then Name_Ok (Name)
            and then File < Max_Files
            and then not Is_Used (T'Old (File_Index (File)))
            and then Is_Used (T (File_Index (File)))
            and then T (File_Index (File)).Gen = T'Old (File_Index (File)).Gen
            and then U64 (T (File_Index (File)).Kind) = Kind
            and then U64 (T (File_Index (File)).Parent) = Dir
            and then T (File_Index (File)).Name = Name
            and then T (File_Index (File)).Length = 0
            and then
              (for all F in File_Index =>
                 (if F /= File_Index (File) then T (F) = T'Old (F)))
          else T = T'Old
            and then D = D'Old
            and then
              (Status = Status_Exists
               or else Status = Status_Full
               or else Status = Status_Request
               or else Status = Status_Not_Found
               or else Status = Status_Not_Dir)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_create";

   --  El bloque del disco que guarda la posición Slot del archivo, y cuántos
   --  bytes del archivo caben en él. El archivo va por manejador (File, Gen),
   --  como en todas las operaciones siguientes: si ya no vale, Status_Stale.
   procedure Block_Of
     (T : Table; O : Owner_Map; D : Depth_Map; File, Gen, Slot : U64;
      Block, Bytes : out U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       (if Status = Status_Ok
        then Opened (T, File, Gen)
          and then Slot < File_Blocks
          and then In_File (T (File_Index (File)), Slot_Index (Slot))
          and then not Is_Dir (T (File_Index (File)))
          and then Block = U64 (T (File_Index (File)).Blocks (Slot_Index (Slot)))
          and then Block >= First_Data
          and then Block < Max_Blocks
          and then Bytes >= 1
          and then Bytes <= Block_Bytes
        else Status = Status_Request
          or else Status = Status_Stale
          or else Status = Status_Is_Dir),
     Export,
     Convention    => C,
     External_Name => "fb_fs_block_of";

   --  Lo que nombra un manejador: su tipo y su longitud (Hito 39). La raíz es
   --  un directorio de longitud 0.
   procedure Stat
     (T : Table; O : Owner_Map; D : Depth_Map; File, Gen : U64;
      Kind, Length : out U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       (if Status = Status_Ok
        then Dir_Opened (T, File, Gen)
          or else
            (Opened (T, File, Gen)
             and then Kind = U64 (T (File_Index (File)).Kind)
             and then Length = U64 (T (File_Index (File)).Length))
        elsif Status = Status_Stale
        then File < Max_Files and then not Opened (T, File, Gen)
        else Status = Status_Request
          and then (File >= Max_Files and then not Dir_Opened (T, File, Gen))),
     Export,
     Convention    => C,
     External_Name => "fb_fs_stat";

   function Write_Allowed
     (T : Table; O : Owner_Map; File, Gen, Slot, Bytes, Block : U64)
      return Boolean
   is (Opened (T, File, Gen)
       and then Slot < File_Blocks
       and then Bytes >= 1
       and then Bytes <= Block_Bytes
       and then Block >= First_Data
       and then Block < Max_Blocks
       and then not Is_Dir (T (File_Index (File)))
       and then Integer (Slot) <= Count (T (File_Index (File)))
       and then not Owned (O, Block_Index (Block)))
   with Pre => Entries_Ok (T);

   --  Dónde escribir Bytes bytes en la posición Slot del archivo (una que ya
   --  tiene o la siguiente a la última): siempre un bloque libre, también al
   --  reescribir (copia al escribir). No cambia nada: el servidor escribe los
   --  datos y después llama a Commit_Write. Como ningún archivo de la tabla
   --  nombra ese bloque (Not_In_Table), escribirlo no cambia ningún archivo
   --  de la tabla que hay en el disco, se corte la luz cuando se corte.
   procedure Plan_Write
     (T : Table; O : Owner_Map; D : Depth_Map; File, Gen, Slot, Bytes : U64;
      Block : out U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       (if Status = Status_Ok
        then Write_Allowed (T, O, File, Gen, Slot, Bytes, Block)
          and then Not_In_Table (T, Block)
        else Status = Status_Request
          or else Status = Status_Stale
          or else Status = Status_Full
          or else Status = Status_Is_Dir),
     Export,
     Convention    => C,
     External_Name => "fb_fs_plan_write";

   --  Anota en la tabla y en el mapa la escritura planeada. La longitud pasa a
   --  ser al menos el final de lo escrito; si la posición ya tenía bloque, el
   --  viejo queda libre. Solo cambia la entrada del archivo, y de ella solo
   --  la longitud y ese bloque: un corte deja en el disco la tabla de antes
   --  o la de después, porque una entrada no cruza un sector.
   procedure Commit_Write
     (T : in out Table; O : in out Owner_Map; D : Depth_Map;
      File, Gen, Slot, Bytes, Block : U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       Valid (T, O, D)
       and then Step_Ok (T'Old, T)
       and then
         (if Status = Status_Ok
          then Write_Allowed (T'Old, O'Old, File, Gen, Slot, Bytes, Block)
            and then Opened (T, File, Gen)
            and then Not_In_Table (T'Old, Block)
            and then T (File_Index (File)).Blocks (Slot_Index (Slot)) = U16 (Block)
            and then
              (for all R in Slot_Index =>
                 (if R /= Slot_Index (Slot)
                  then T (File_Index (File)).Blocks (R)
                    = T'Old (File_Index (File)).Blocks (R)))
            and then
              U64 (T (File_Index (File)).Length)
              >= Slot * Block_Bytes + Bytes
            and then T (File_Index (File)).Name = T'Old (File_Index (File)).Name
            and then T (File_Index (File)).Parent = T'Old (File_Index (File)).Parent
            and then
              (for all F in File_Index =>
                 (if F /= File_Index (File) then T (F) = T'Old (F)))
          else Status = Status_Request and then T = T'Old and then O = O'Old),
     Export,
     Convention    => C,
     External_Name => "fb_fs_commit_write";

   --  Borra un archivo, cuyos bloques quedan libres, o un directorio vacío.
   --  Su generación sube: ningún manejador suyo vuelve a valer.
   procedure Delete
     (T : in out Table; O : in out Owner_Map; D : in out Depth_Map;
      File, Gen : U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       Valid (T, O, D)
       and then Step_Ok (T'Old, T)
       and then
         (if Status = Status_Ok
          then Opened (T'Old, File, Gen)
            and then not Is_Used (T (File_Index (File)))
            and then T (File_Index (File)).Gen = T'Old (File_Index (File)).Gen + 1
            and then
              (for all F in File_Index =>
                 (if F /= File_Index (File) then T (F) = T'Old (F)))
            and then
              (for all B in Block_Index =>
                 (if Owned (O'Old, B)
                    and then O'Old (B).File /= U8 (File)
                  then O (B) = O'Old (B)))
          elsif Status = Status_Not_Empty
          then T = T'Old and then O = O'Old and then D = D'Old
            and then Opened (T, File, Gen)
            and then Is_Dir (T (File_Index (File)))
            and then
              (for some F in File_Index =>
                 Is_Used (T (F)) and then U64 (T (F).Parent) = File)
          else T = T'Old
            and then O = O'Old
            and then D = D'Old
            and then (Status = Status_Request or else Status = Status_Stale)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_delete";

   --  Cambia el directorio y el nombre de una entrada: solo esa entrada, y de
   --  ella solo esos dos campos, así que un corte deja la tabla de antes o la
   --  de después. Si ya hay otra entrada con ese nombre en Dir, no la
   --  sustituye (Status_Exists). Un directorio no puede ir dentro de sí mismo
   --  ni de un descendiente suyo (Status_Request): las profundidades nuevas
   --  se calculan desde cero, y con un ciclo no se pueden calcular. La
   --  generación no cambia: el manejador sigue valiendo.
   procedure Rename
     (T : in out Table; O : Owner_Map; D : in out Depth_Map;
      File, Gen, Dir : U64; Name : Name_Array; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       Valid (T, O, D)
       and then Step_Ok (T'Old, T)
       and then
         (if Status = Status_Ok
          then Opened (T'Old, File, Gen)
            and then Opened (T, File, Gen)
            and then Dir_Ok (T'Old, Dir)
            and then Moved (T'Old (File_Index (File)), T (File_Index (File)))
            and then U64 (T (File_Index (File)).Parent) = Dir
            and then T (File_Index (File)).Name = Name
            and then
              (for all F in File_Index =>
                 (if F /= File_Index (File) then T (F) = T'Old (F)))
          else T = T'Old
            and then D = D'Old
            and then
              (Status = Status_Request
               or else Status = Status_Stale
               or else Status = Status_Not_Found
               or else Status = Status_Not_Dir
               or else Status = Status_Exists)),
     Export,
     Convention    => C,
     External_Name => "fb_fs_rename";

   --  La primera entrada en uso del directorio Dir (por manejador) desde
   --  From, o Max_Files si no hay más.
   procedure Next_In
     (T : Table; O : Owner_Map; D : Depth_Map; Dir, Gen, From : U64;
      File : out U64; Status : out U64)
   with
     Global        => null,
     Pre           => Valid (T, O, D),
     Post          =>
       (if Status /= Status_Ok
        then File = Max_Files
          and then not Dir_Opened (T, Dir, Gen)
          and then
            (Status = Status_Request
             or else Status = Status_Stale
             or else Status = Status_Not_Dir)
        elsif File < Max_Files
        then Dir_Opened (T, Dir, Gen)
          and then File >= From
          and then Is_Used (T (File_Index (File)))
          and then U64 (T (File_Index (File)).Parent) = Dir
          and then
            (for all F in File_Index =>
               (if U64 (F) >= From and then U64 (F) < File
                then not Is_Used (T (F)) or else U64 (T (F).Parent) /= Dir))
        else File = Max_Files
          and then Dir_Opened (T, Dir, Gen)
          and then
            (for all F in File_Index =>
               (if U64 (F) >= From
                then not Is_Used (T (F)) or else U64 (T (F).Parent) /= Dir))),
     Export,
     Convention    => C,
     External_Name => "fb_fs_next_in";

   --  Bloques libres: para las pruebas y las medidas.
   function Free_Blocks (O : Owner_Map) return U64 with
     Global        => null,
     Post          => Free_Blocks'Result <= Max_Blocks - First_Data,
     Export,
     Convention    => C,
     External_Name => "fb_fs_free_blocks";

end Fs_Core;
