use cozy_chess::*;

#[derive(PartialEq, Clone, Debug)]
pub struct BoardStack {
    board: Board,
    move_stack: Vec<u64>,
    status: GameStatus,
}

impl BoardStack {
    pub fn new(board: Board) -> Self {
        Self {
            status: board.status(),
            board,
            move_stack: Vec::new(),
        }
    }

    // get number of repetitions for decoder.rs

    pub fn get_reps(&self) -> usize {
        // reps only for the current position, not the global maximum of repetitions recorded
        let target = self.board.hash();
        (&self.move_stack).iter().filter(|&x| *x == target).count()
        
    }

    // play function to be called in selfplay.rs
    pub fn play(&mut self, mv: Move) {
        assert!(self.status == GameStatus::Ongoing); // check if prev board is valid (can play a move)
        self.move_stack.push(self.board.hash());
        self.board.play(mv);
        self.status = if self.get_reps() == 2 {
            GameStatus::Drawn
        } else {
            self.board.status()
        };
        
    }

    pub fn board(&self) -> &Board {
        &self.board
    }

    pub fn status(&self) -> GameStatus {
        self.status
    }
}
