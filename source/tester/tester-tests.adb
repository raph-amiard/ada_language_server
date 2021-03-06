------------------------------------------------------------------------------
--                         Language Server Protocol                         --
--                                                                          --
--                        Copyright (C) 2018, AdaCore                       --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Characters.Latin_1;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with GNAT.OS_Lib;

with Spawn.String_Vectors;
with Spawn.Processes.Monitor_Loop;

package body Tester.Tests is

   type Command_Kind is (Start, Stop, Send);

   procedure Do_Start
     (Self    : in out Test'Class;
      Command : GNATCOLL.JSON.JSON_Value);

   procedure Do_Stop
     (Self    : in out Test'Class;
      Command : GNATCOLL.JSON.JSON_Value);

   procedure Do_Send
     (Self    : in out Test'Class;
      Command : GNATCOLL.JSON.JSON_Value);

   --------------
   -- Do_Abort --
   --------------

   not overriding procedure Do_Abort (Self : Test) is
   begin
      GNAT.OS_Lib.OS_Exit (1);
   end Do_Abort;

   -------------
   -- Do_Fail --
   -------------

   not overriding procedure Do_Fail (Self : Test; Message : String) is
      pragma Unreferenced (Self);
   begin
      Ada.Text_IO.Put_Line ("Test failed:" & Message);
   end Do_Fail;

   -------------
   -- Do_Send --
   -------------

   procedure Do_Send
     (Self    : in out Test'Class;
      Command : GNATCOLL.JSON.JSON_Value)
   is
      New_Line : constant String :=
        (Ada.Characters.Latin_1.CR, Ada.Characters.Latin_1.LF);
      Request : constant GNATCOLL.JSON.JSON_Value := Command.Get ("request");
      Wait    : constant GNATCOLL.JSON.JSON_Array := Command.Get ("wait").Get;
      Text    : constant String := Request.Write;
      Image   : constant String := Positive'Image (Text'Length);
      Header  : constant String := "Content-Length:" & Image
        & New_Line & New_Line;
   begin
      Self.Waits := Wait;
      Ada.Strings.Unbounded.Append (Self.To_Write, Header);
      Ada.Strings.Unbounded.Append (Self.To_Write, Text);

      if Self.Can_Write then
         Self.Listener.Standard_Input_Available;
      end if;

      loop
         Spawn.Processes.Monitor_Loop (Timeout => 1);
         exit when GNATCOLL.JSON.Length (Self.Waits) = 0;
      end loop;
   end Do_Send;

   --------------
   -- Do_Start --
   --------------

   procedure Do_Start
     (Self    : in out Test'Class;
      Command : GNATCOLL.JSON.JSON_Value)
   is
      Cmd : constant GNATCOLL.JSON.JSON_Array := Command.Get ("cmd");
      Args : Spawn.String_Vectors.UTF_8_String_Vector;
   begin
      for J in 2 .. GNATCOLL.JSON.Length (Cmd) loop
         Args.Append (GNATCOLL.JSON.Get (Cmd, J).Get);
      end loop;

      Self.Server.Set_Program (GNATCOLL.JSON.Get (Cmd, 1).Get);
      Self.Server.Set_Arguments (Args);
      Self.Server.Set_Listener (Self.Listener'Unchecked_Access);
      Self.Server.Start;

      loop
         Spawn.Processes.Monitor_Loop (Timeout => 1);
         exit when Self.Server.Status in Spawn.Processes.Running;
      end loop;
   end Do_Start;

   -------------
   -- Do_Stop --
   -------------

   procedure Do_Stop
     (Self    : in out Test'Class;
      Command : GNATCOLL.JSON.JSON_Value)
   is
      Exit_Code : constant Integer := Command.Get ("exit_code").Get;
   begin
      Self.Server.Close_Standard_Input;

      loop
         Spawn.Processes.Monitor_Loop (Timeout => 1);
         exit when Self.Server.Status in Spawn.Processes.Not_Running;
      end loop;

      if Self.Server.Exit_Code /= Exit_Code then
         Self.Do_Fail ("Unexpected exit code:" & (Self.Server.Exit_Code'Img));
      end if;
   end Do_Stop;

   --------------------
   -- Error_Occurred --
   --------------------

   overriding procedure Error_Occurred
    (Self          : in out Listener;
     Process_Error : Integer)
   is
   begin
      Ada.Text_IO.Put_Line ("Error on server start:" & (Process_Error'Img));
      Ada.Text_IO.Put ("   ");
      Ada.Text_IO.Put_Line (GNAT.OS_Lib.Errno_Message (Process_Error));
      Self.Test.Do_Abort;
   end Error_Occurred;

   ---------------------
   -- Execute_Command --
   ---------------------

   not overriding procedure Execute_Command
     (Self    : in out Test;
      Command : GNATCOLL.JSON.JSON_Value)
   is
      procedure Execute (Name : String; Value : GNATCOLL.JSON.JSON_Value);

      -------------
      -- Execute --
      -------------

      procedure Execute (Name : String; Value : GNATCOLL.JSON.JSON_Value) is
         Kind : constant Command_Kind := Command_Kind'Value (Name);
      begin
         Self.Index := Self.Index + 1;

         case Kind is
            when Start =>
               Self.Do_Start (Value);
            when Stop =>
               Self.Do_Stop (Value);
            when Send =>
               Self.Do_Send (Value);
         end case;
      end Execute;

   begin
      Command.Map_JSON_Object (Execute'Access);
   end Execute_Command;

   ---------
   -- Run --
   ---------

   not overriding procedure Run
     (Self     : in out Test;
      Commands : GNATCOLL.JSON.JSON_Array)
   is
   begin
      while Self.Index <= GNATCOLL.JSON.Length (Commands) loop
         declare
            Command : constant GNATCOLL.JSON.JSON_Value :=
              GNATCOLL.JSON.Get (Commands, Self.Index);
         begin
            Self.Execute_Command (Command);
         end;
      end loop;
   end Run;

   ------------------------------
   -- Standard_Error_Available --
   ------------------------------

   overriding procedure Standard_Error_Available (Self : in out Listener) is
   begin
      loop
         declare
            Raw  : Ada.Streams.Stream_Element_Array (1 .. 1024);
            Last : Ada.Streams.Stream_Element_Count;
            Text : String (1 .. 1024) with Import, Address => Raw'Address;
         begin
            Self.Test.Server.Read_Standard_Error (Raw, Last);
            exit when Last in 0;
            Ada.Text_IO.Put (Text (1 .. Natural (Last)));
         end;
      end loop;

      --  Self.Test.Do_Abort;
   end Standard_Error_Available;

   ------------------------------
   -- Standard_Input_Available --
   ------------------------------

   overriding procedure Standard_Input_Available (Self : in out Listener) is
      Test : Tester.Tests.Test renames Self.Test.all;
      To_Write_Len : constant Natural :=
        Ada.Strings.Unbounded.Length (Test.To_Write);
      Piece_Length : constant Natural := To_Write_Len - Test.Written;
   begin
      if Piece_Length > 0 then
         declare
            Slice : String := Ada.Strings.Unbounded.Slice
              (Test.To_Write, Test.Written + 1, To_Write_Len);
            subtype Raw_Array is Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Count'Last);
            Raw   : Raw_Array
              with Import, Address => Slice'Address;
            Last  : Ada.Streams.Stream_Element_Count;
         begin
            Test.Server.Write_Standard_Input (Raw (1 .. Slice'Length), Last);
            Test.Written := Test.Written + Natural (Last);
            Self.Test.Can_Write := Natural (Last) >= 1;

            if To_Write_Len = Test.Written then
               Test.Written := 0;
               Test.To_Write := Ada.Strings.Unbounded.Null_Unbounded_String;
            end if;
         end;
      else
         Self.Test.Can_Write := True;
      end if;
   end Standard_Input_Available;

   -------------------------------
   -- Standard_Output_Available --
   -------------------------------

   overriding procedure Standard_Output_Available (Self : in out Listener) is
      use Ada.Strings.Unbounded;
      use Ada.Strings.Fixed;
            use type GNATCOLL.JSON.JSON_Value_Type;

      procedure Parse_Headers
        (Buffer : String; Content_Length : out Positive);
      --  Parse headers in Buffer and return Content-Length

      procedure Sweep_Waits (JSON : GNATCOLL.JSON.JSON_Value);
      --  Find matching wait if any and delete it from Test.Waits

      function Match (Left, Right : GNATCOLL.JSON.JSON_Value) return Boolean
        with Pre => Left.Kind = GNATCOLL.JSON.JSON_Object_Type
                      and Right.Kind = GNATCOLL.JSON.JSON_Object_Type;
      --  Check if Left has all properties from Right.

      New_Line : constant String :=
        (Ada.Characters.Latin_1.CR, Ada.Characters.Latin_1.LF);

      Test : Tester.Tests.Test renames Self.Test.all;

      -------------------
      -- Parse_Headers --
      -------------------

      procedure Parse_Headers
        (Buffer         : String;
         Content_Length : out Positive)
      is
         function Skip (Pattern : String) return Boolean;
         --  Find Pattern in current position of Buffer and skip it

         Next : Positive := Buffer'First;
         --  Current position in Buffer

         ----------
         -- Skip --
         ----------

         function Skip (Pattern : String) return Boolean is
         begin
            if Next + Pattern'Length - 1 <= Buffer'Last
              and then Buffer (Next .. Next + Pattern'Length - 1) = Pattern
            then
               Next := Next + Pattern'Length;
               return True;
            else
               return False;
            end if;
         end Skip;

      begin
         while Next < Buffer'Last loop
            if Skip ("Content-Type: ") then
               Next := Index (Buffer, New_Line);
               pragma Assert (Next /= 0);
            elsif Skip ("Content-Length: ") then
               declare
                  From : constant Positive := Next;
               begin
                  Next := Index (Buffer, New_Line);
                  pragma Assert (Next /= 0);
                  Content_Length := Positive'Value (Buffer (From .. Next - 1));
               end;
            else
               raise Constraint_Error with "Unexpected header:" & Buffer;
            end if;

            Next := Next + New_Line'Length;
         end loop;
      end Parse_Headers;

      -----------
      -- Match --
      -----------

      function Match (Left, Right : GNATCOLL.JSON.JSON_Value) return Boolean is
         procedure Match_Proerty
           (Name  : String;
            Value : GNATCOLL.JSON.JSON_Value);
         --  Match one property in JSON object

         Success : Boolean := True;

         -------------------
         -- Match_Proerty --
         -------------------

         procedure Match_Proerty
           (Name  : String;
            Value : GNATCOLL.JSON.JSON_Value)
         is
            use type GNATCOLL.JSON.JSON_Value;
         begin
            if Left.Has_Field (Name) then
               declare
                  Prop : constant GNATCOLL.JSON.JSON_Value := Left.Get (Name);
               begin
                  if Prop.Kind /= Value.Kind then
                     Success := False;
                     return;
                  end if;

                  case Prop.Kind is
                     when GNATCOLL.JSON.JSON_Object_Type =>
                        if not Match (Prop, Value) then
                           Success := False;
                        end if;

                     when GNATCOLL.JSON.JSON_Array_Type =>
                        raise Program_Error with "Unimplemented";

                     when others =>
                        if Prop /= Value then
                           Success := False;
                        end if;
                  end case;
               end;
            else
               Success := False;
            end if;
         end Match_Proerty;

      begin
         Right.Map_JSON_Object (Match_Proerty'Access);

         return Success;
      end Match;

      -----------------
      -- Sweep_Waits --
      -----------------

      procedure Sweep_Waits (JSON : GNATCOLL.JSON.JSON_Value) is
         Found : Natural := 0;
      begin
         for J in 1 .. GNATCOLL.JSON.Length (Test.Waits) loop
            declare
               Wait : constant GNATCOLL.JSON.JSON_Value :=
                 GNATCOLL.JSON.Get (Test.Waits, J);
            begin
               if Match (JSON, Wait) then
                  Found := J;
                  exit;
               end if;
            end;
         end loop;

         if Found /= 0 then
            declare
               Copy : GNATCOLL.JSON.JSON_Array;
            begin
               for J in 1 .. GNATCOLL.JSON.Length (Test.Waits) loop
                  if J /= Found then
                     declare
                        Wait : constant GNATCOLL.JSON.JSON_Value :=
                          GNATCOLL.JSON.Get (Test.Waits, J);
                     begin
                        GNATCOLL.JSON.Append (Copy, Wait);
                     end;
                  end if;
               end loop;

               Test.Waits := Copy;
            end;
         end if;
      end Sweep_Waits;

   begin
      loop
         declare
            Raw  : Ada.Streams.Stream_Element_Array (1 .. 1024);
            Last : Ada.Streams.Stream_Element_Count;
            Text : String (1 .. Raw'Length)
              with Import, Address => Raw'Address;
            Start : Natural;
         begin
            Self.Test.Server.Read_Standard_Output (Raw, Last);

            exit when Last in 0;

            Append (Test.Buffer, Text (1 .. Positive (Last)));

            loop
               if Test.To_Read = 0 then
                  --  Look for end of header list
                  Start := Index (Test.Buffer, New_Line & New_Line);

                  if Start /= 0 then
                     Parse_Headers
                       (Slice (Test.Buffer, 1, Start + 1),
                        Test.To_Read);

                     Delete (Test.Buffer, 1, Start + 2 * New_Line'Length - 1);
                  end if;
               end if;

               exit when Test.To_Read = 0
                 or else Length (Test.Buffer) < Test.To_Read;

               declare
                  JSON : constant GNATCOLL.JSON.JSON_Value :=
                    GNATCOLL.JSON.Read (Head (Test.Buffer, Test.To_Read));
               begin
                  Sweep_Waits (JSON);
                  Delete (Test.Buffer, 1, Test.To_Read);
                  Test.To_Read := 0;
               end;
            end loop;
         end;
      end loop;
   end Standard_Output_Available;

end Tester.Tests;
