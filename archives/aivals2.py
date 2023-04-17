# AI MOVE LEARNER
# zan1ling4 真零 | TrueZero
import numpy as np
import chess
import torch
from torch import nn
from torch import optim
import pandas as pd

# Import puzzles

df = pd.read_csv("./puzzles copy.csv")

setup = df["FEN"].to_list()

soln = df["Moves"].to_list()


class Agent(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(832, 832)
        self.hidden_layers = nn.ModuleList()
        for _ in range(10):
            self.hidden_layers.append(nn.Linear(832, 832))
        self.fc_out = nn.Linear(832, 1)
        self.optimizer = optim.Adam(self.parameters(), lr=1e-1)
        self.scheduler = optim.lr_scheduler.StepLR(
            self.optimizer, step_size=10, gamma=0.5
        )
        self.loss = nn.MSELoss()

    def forward(self, x):
        x = torch.relu(self.fc1(x))
        for layer in self.hidden_layers:
            x = torch.relu(layer(x))
        x = self.fc_out(x)
        return x

    def generate_move(self, board):
        legal_moves = list(board.legal_moves)
        if not legal_moves:
            return None

        inputs = []
        for move in legal_moves:
            board.push(move)
            board_array = board_data(board)
            inputs.append(board_array)
            board.pop()

        inputs = np.array(inputs)
        if inputs.shape[0] == 0:  # No valid moves
            return None

        inputs = torch.tensor(inputs, dtype=torch.float)
        outputs = self.forward(inputs)
        best_move_idx = torch.argmax(outputs).item()
        return legal_moves[best_move_idx]

    def load_weights(self, path):
        self.load_state_dict(torch.load(path))


def board_data(board):
    board_array = np.zeros((8, 8, 13), dtype=np.int8)
    for i in range(64):
        piece = board.piece_at(i)
        if piece is not None:
            color = int(piece.color)
            piece_type = piece.piece_type - 1
            board_array[i // 8][i % 8][piece_type + 6 * color] = 1
        else:
            board_array[i // 8][i % 8][-1] = 1
    board_array = board_array.flatten()
    return board_array


def play_game(agent1, index):
    with open("valscopy.txt", "a+") as f:
        f.write("Puzzle " + str(index) + "\n")
    correct = 0
    board = chess.Board()
    batch_inputs = []
    batch_targets = []
    # setup board for puzzle
    board.set_fen(setup[index])
    puzzle_soln = soln[index].split(" ")
    counter = 0
    while counter < len(puzzle_soln):
        pre_board = board.copy()
        move = str(agent1.generate_move(board))
        if move == puzzle_soln[counter]:
            correct += 1
        else:
            agent1 = mutate(agent1, 0.2, 1)
        board.push(chess.Move.from_uci(puzzle_soln[counter]))
        batch_inputs.append(board_data(pre_board))
        batch_targets.append(
            agent1.forward(torch.tensor(board_data(board), dtype=torch.float)).item())
        
        counter += 1
        # Append final target value when game is over
    score = correct
    batch_targets[-1] = score  # set the last target value to score
    accuracy = score / len(puzzle_soln)
    with open("valscopy.txt", "a+") as f:
        f.write(str(score) + " " + str(accuracy) + "\n")
        # Train the agents on the batch
    if len(batch_inputs) > 0:
        batch_inputs = np.array(batch_inputs)
        batch_targets = np.array(batch_targets)
        inputs = torch.tensor(batch_inputs, dtype=torch.float)
        targets = torch.tensor(batch_targets, dtype=torch.float).view(-1, 1)
        outputs = agent1.forward(inputs)
        loss = agent1.loss(outputs, targets)
        loss.backward()
        # NOTE: UserWarning: Detected call of `lr_scheduler.step()` before `optimizer.step()`. In PyTorch 1.1.0 and later, you should call them in the opposite order: `optimizer.step()` before `lr_scheduler.step()`.  Failure to do this will result in PyTorch skipping the first value of the learning rate schedule. See more details at https://pytorch.org/docs/stable/optim.html#how-to-adjust-learning-rate
        agent1.optimizer.zero_grad()
        agent1.optimizer.step()
        agent1.scheduler.step()
        board = chess.Board()
        batch_inputs = []
        batch_targets = []
        return score, accuracy


# Define genetic algorithm parameters
POP_SIZE = 10  # 10
MUTATION_RATE = 0.3

# Initialise documents


def mutate(agent, mutation_rate, score):
    # Calculate the new mutation rate based on the game score
    if score < 0:
        mutation_rate = max(0.8, mutation_rate - 0.1)
    elif score > 0:
        mutation_rate = min(0.2, mutation_rate + 0.1)
    # Mutate the agent's parameters
    for param in agent.parameters():
        if np.random.rand() < mutation_rate:
            param.data += torch.randn(param.shape) * np.random.rand()
    return agent


# Initialize the population
population = [Agent() for _ in range(POP_SIZE)]
num_elites = int(POP_SIZE * 0.5)
# Use best agents

for agent in population:
    try:
        index_chooser = np.random.randint(0, num_elites)
        agent.load_weights("./best_agents" + str(index_chooser) + ".pt")
    except FileNotFoundError:
        pass

for i in range(len(population)):
    for j in range(i + 1, len(population)):
        agent1 = population[i]
        agent2 = population[j]

        similarity_threshold = 0.90
        cosine_similarity = nn.CosineSimilarity(dim=0)
        euclidean_distance = nn.PairwiseDistance(p=2, keepdim=True)
        weights1 = [param.data.flatten() for param in agent1.parameters()]
        weights2 = [param.data.flatten() for param in agent2.parameters()]
        for w1, w2 in zip(weights1, weights2):
            distance = euclidean_distance(
                w1.clone().detach(), w2.clone().detach()
            ).item()
            similarity = cosine_similarity(w1, w2).item()
            if similarity > similarity_threshold or distance > similarity_threshold:
                # Mutate one of the agents
                if np.random.rand() < 0.5:
                    agent1 = mutate(agent1, np.random.rand(), np.random.rand())
                else:
                    agent2 = mutate(agent2, np.random.rand(), np.random.rand())

# Play each agent with all puzzles

PUZZLE_SIZE = 4  # insert actual number of puzzles (starting from 1)

scores = np.zeros((POP_SIZE, PUZZLE_SIZE))
accuracy = np.zeros((POP_SIZE, PUZZLE_SIZE))
val_table = []
for i in range(POP_SIZE):
    for j in range(PUZZLE_SIZE):
        scores[i][j], accuracy[i][j] = play_game(population[i], j)
        val_table.append(scores[i][j])
# Rank the agents by their scores
ranked_indices = np.argsort(np.sum(scores, axis=1))[::-1]

ranked_population = [population[i] for i in ranked_indices]

# Create a new population through selection, crossover, and mutation
new_population = []

# Keep the top-performing agents in the population
elites = ranked_population[:num_elites]
for elite in elites:
    new_population.append(elite)
# Select parents for breeding using tournament selection
tournament_size = 3  # 4
for i in range(num_elites, POP_SIZE):
    parent1 = None
    parent2 = None
    for _ in range(tournament_size):
        idx = np.random.randint(POP_SIZE)
        if parent1 is None or scores[idx][i] > scores[parent1][i]:
            p1 = idx
        elif parent2 is None or scores[idx][i] > scores[parent2][i]:
            p2 = idx
            population[i].optimizer.step()
            population[i].scheduler.step()
            parent1 = ranked_population[p1]
            parent2 = ranked_population[p2]

            # Perform crossover to create a new child
            child = Agent()
            for name, param in child.named_parameters():
                if np.random.rand() > 0.5:
                    param.data.copy_(parent1.state_dict()[name].data)
                else:
                    param.data.copy_(parent2.state_dict()[name].data)

            # Perform mutation on the child
            for agent_score, agent in zip(accuracy, population):
                # Mutate the agent based on its score
                avg_score = 0
                avg_counter = 0
                for item in agent_score:
                    if item != 0:
                        avg_score += item
                        avg_counter += 1
                avg_score = avg_score / avg_counter
                agent = mutate(agent, MUTATION_RATE, avg_score)
                new_population.append(agent)
                population = new_population
for agent_index in range(num_elites):
    torch.save(
        ranked_population[agent_index].state_dict(),
        "./best_puzzle_agents" + str(agent_index) + ".pt",
    )

with open("accuracycopy.txt", "a+") as f:
    f.write(str(accuracy) + "\n")
with open("scorescopy.txt", "a+") as f:
    f.write(str(scores) + "\n")
